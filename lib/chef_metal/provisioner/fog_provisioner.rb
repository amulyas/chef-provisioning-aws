require 'chef_metal/provisioner'

module ChefMetal
  class Provisioner

    # Provisions machines in vagrant.
    class FogProvisioner < Provisioner

      include Chef::Mixin::ShellOut

      # Create a new vagrant provisioner.
      #
      # ## Parameters
      # compute_options - hash of options to be passed to Fog::Compute.new
      def initialize(compute_options)
        @compute_options = compute_options
      end

      attr_reader :compute_options

      # Acquire a machine, generally by provisioning it.  Returns a Machine
      # object pointing at the machine, allowing useful actions like setup,
      # converge, execute, file and directory.  The Machine object will have a
      # "node" property which must be saved to the server (if it is any
      # different from the original node object).
      #
      # ## Parameters
      # provider - the provider object that is calling this method.
      # node - node object (deserialized json) representing this machine.  If
      #        the node has a provisioner_options hash in it, these will be used
      #        instead of options provided by the provisioner.  TODO compare and
      #        fail if different?
      #        node will have node['normal']['provisioner_options'] in it with any options.
      #        It is a hash with this format:
      #
      #           -- provisioner_url: fog:<relevant_fog_options>
      #           -- bootstrap_options: hash of options to pass to compute.servers.create
      #           -- is_windows: true if windows.  TODO detect this from ami?
      #
      #        Example bootstrap_options for ec2:
      #           :image_id=>'ami-311f2b45',
      #           :flavor_id=>'t1.micro',
      #           :key_name => 'pey-pair-name'
      #
      #        node['normal']['provisioner_output'] will be populated with information
      #        about the created machine.  For vagrant, it is a hash with this
      #        format:
      #
      #           -- provisioner_url: fog:<relevant_fog_options>
      #           -- server_id: the ID of the server so it can be found again
      #
      def acquire_machine(provider, node)
        # Set up the modified node data
        provisioner_options = node['normal']['provisioner_options']
        provisioner_output = node['normal']['provisioner_output'] || {
          'provisioner_url' => provisioner_url
        }

        if provisioner_output['provisioner_url'] != provisioner_url
          raise "Switching providers for a machine is not currently supported!  Use machine :destroy and then re-create the machine on the new provider."
        end

        node['normal']['provisioner_output'] = provisioner_output

        if provisioner_output['server_id']

          # If the server already exists, make sure it is up

          # TODO verify that the server info matches the specification (ami, etc.)\
          server = server_for(node)
          if !server.ready?
            provider.converge_by "start machine #{node['name']} (#{server.id} on #{provisioner_url})" do
              server.start
            end
          end
          machine_for(node, server)
        else

          # If the server does not exist, create it

          bootstrap_options = symbolize_keys(provisioner_options['bootstrap_options'] || {})
          description = [ "create machine #{node['name']} on #{provisioner_url}" ]
          bootstrap_options.each_pair { |key,value| description << "  - #{key}: #{value.inspect}" }
          provider.converge_by description do
            server = compute.servers.bootstrap(bootstrap_options)
            provisioner_output['server_id'] = server.id
          end
          # Create machine object for callers to use
          machine_for(node, server)
        end
      end

      # Connect to machine without acquiring it
      def connect_to_machine(node)
        machine_for(node)
      end

      def delete_machine(provider, node)
        if node['normal']['provisioner_output'] && node['normal']['provisioner_output']['server_id']
          server = compute.servers.get(node['normal']['provisioner_output']['server_id'])
          provider.converge_by "destroy machine #{node['name']} (#{server.id} at #{provisioner_url}" do
            server.destroy
          end
          convergence_strategy_for(node).delete_chef_objects(provider, node)
        else
          raise "Server for node #{node['name']} has not been created!"
        end
      end

      def compute
        @compute ||= begin
          require 'fog/compute'
          require 'fog'
          Fog::Compute.new(compute_options)
        end
      end

      def provisioner_url
        provider_identifier = case compute_options['provider']
          when 'AWS'
            compute_options['aws_access_key_id']
          else
            '???'
        end
        "fog:#{compute_options['provider']}:#{provider_identifier}"
      end

      protected

      def symbolize_keys(options)
        options.inject({}) { |result,key,value| result[key.to_sym] = value; result }
      end

      def server_for(node)
        if node['normal']['provisioner_output'] && node['normal']['provisioner_output']['server_id']
          server = compute.servers.get(node['normal']['provisioner_output']['server_id'])
        else
          raise "Server for node #{node['name']} has not been created!"
        end
      end

      def machine_for(node, server = nil)
        if !server
          server = server_for(node)
        end

        if node['normal']['provisioner_options']['is_windows']
          require 'chef_metal/machine/windows_machine'
          ChefMetal::Machine::WindowsMachine.new(node, transport_for(server), convergence_strategy_for(node))
        else
          require 'chef_metal/machine/unix_machine'
          ChefMetal::Machine::UnixMachine.new(node, transport_for(server), convergence_strategy_for(node))
        end
      end

      def convergence_strategy_for(node)
        if node['normal']['provisioner_options']['is_windows']
          require 'chef_metal/convergence_strategy/install_msi'
          ChefMetal::ConvergenceStrategy::InstallMsi.new
        else
          require 'chef_metal/convergence_strategy/install_sh'
          ChefMetal::ConvergenceStrategy::InstallSh.new
        end
      end

      def transport_for(server)
        # TODO winrm
        create_ssh_transport(server)
      end

      def create_ssh_transport(server)
        require 'chef_metal/transport/ssh'

        ssh_options = {
#          :user_known_hosts_file => vagrant_ssh_config['UserKnownHostsFile'],
#          :paranoid => yes_or_no(vagrant_ssh_config['StrictHostKeyChecking']),
          :keys => [ server.private_key ],
          :keys_only => true
        }
        options = {
          :prefix => 'sudo '
        }
        ChefMetal::Transport::SSH.new(server.ip_address, server.username, ssh_options, options)
      end
    end
  end
end