module Fog
  module Compute
    class Vsphere

      module Shared
        private
        def vm_clone_check_options(options)
          default_options = {
            'force'        => false,
            'linked_clone' => false,
          }
          options = default_options.merge(options)
          # Backwards compat for "path" option
          options["template_path"] ||= options["path"]
          options["path"] ||= options["template_path"]
          required_options = %w{ datacenter template_path name }
          required_options.each do |param|
            raise ArgumentError, "#{required_options.join(', ')} are required" unless options.has_key? param
          end
          # TODO This is ugly and needs to rethink mocks
          unless ENV['FOG_MOCK']
            raise ArgumentError, "#{options["datacenter"]} Doesn't Exist!" unless get_datacenter(options["datacenter"])
            raise ArgumentError, "#{options["template_path"]} Doesn't Exist!" unless get_virtual_machine(options["template_path"], options["datacenter"])
          end
          options
        end
      end

      class Real
        include Shared

        # Clones a VM from a template or existing machine on your vSphere 
        # Server.  
        #
        # ==== Parameters
        # * options<~Hash>:
        #   * 'datacenter'<~String> - *REQUIRED* Datacenter name your cloning 
        #     in. Make sure this datacenter exists, should if you're using
        #     the clone function in server.rb model.
        #   * 'template_path'<~String> - *REQUIRED* The path to the machine you 
        #     want to clone FROM. Relative to Datacenter (Example:
        #     "FolderNameHere/VMNameHere")
        #   * 'name'<~String> - *REQUIRED* The VMName of the Destination  
        #   * 'dest_folder'<~String> - Destination Folder of where 'name' will
        #     be placed on your cluster. Relative Path to Datacenter E.G.
        #     "FolderPlaceHere/anotherSub Folder/onemore"
        #   * 'power_on'<~Boolean> - Whether to power on machine after clone. 
        #     Defaults to true.
        #   * 'wait'<~Boolean> - Whether the method should wait for the virtual
        #     machine to finish cloning before returning information from 
        #     vSphere. Broken right now as you cannot return a model of a serer
        #     that isn't finished cloning. Defaults to True
        #   * 'resource_pool'<~Array> - The resource pool on your datacenter 
        #     cluster you want to use. Only works with clusters within same
        #     same datacenter as where you're cloning from. Datacenter grabbed
        #     from template_path option. 
        #     Example: ['cluster_name_here','resource_pool_name_here']
        #   * 'datastore'<~String> - The datastore you'd like to use.
        #       (datacenterObj.datastoreFolder.find('name') in API)
        #   * 'transform'<~String> - Not documented - see http://www.vmware.com/support/developer/vc-sdk/visdk41pubs/ApiReference/vim.vm.RelocateSpec.html
        #   * customization_spec<~Hash>: Options are marked as required if you
        #     use this customization_spec. Static IP Settings not configured.
        #     This only support cloning and setting DHCP on the first interface
        #     * 'domain'<~String> - *REQUIRED* This is put into 
        #       /etc/resolve.conf (we hope)
        #     * 'hostname'<~String> - Hostname of the Guest Os - default is 
        #       options['name']
        #     * 'hw_utc_clock'<~Boolean> - *REQUIRED* Is hardware clock UTC? 
        #       Default true
        #     * 'time_zone'<~String> - *REQUIRED* Only valid linux options 
        #       are valid - example: 'America/Denver'
        #
        def vm_clone(options = {})
          # Option handling
          options = vm_clone_check_options(options)

          # Added for people still using options['path']
          template_path = options['path'] || options['template_path']
          
          # Default wait enabled
          options['wait'] = true

          # Options['template_path']<~String>
          # Added for people still using options['path']
          template_path = options['path'] || options['template_path']
          # Now find the template itself using the efficient find method
          vm_mob_ref = get_vm_ref(template_path, options['datacenter'])

          # Options['dest_folder']<~String>
          # Grab the destination folder object if it exists else use cloned mach
          dest_folder = get_raw_vmfolder(options['dest_folder'], options['datacenter']) if options.has_key?('dest_folder')
          dest_folder ||= vm_mob_ref.parent

          # Options['resource_pool']<~Array>
          # Now find _a_ resource pool to use for the clone if one is not specified
          if ( options.has_key?('resource_pool') && options['resource_pool'].is_a?(Array) && options['resource_pool'].length == 2 )
            cluster_name = options['resource_pool'][0]
            pool_name = options['resource_pool'][1]
            resource_pool = get_raw_resource_pool(pool_name, cluster_name, options['datacenter'])
          elsif ( vm_mob_ref.resourcePool == nil )
            # If the template is really a template then there is no associated resource pool,
            # so we need to find one using the template's parent host or cluster
            esx_host = vm_mob_ref.collect!('runtime.host')['runtime.host']
            # The parent of the ESX host itself is a ComputeResource which has a resourcePool
            resource_pool = esx_host.parent.resourcePool
          end
          # If the vm given did return a valid resource pool, default to using it for the clone.
          # Even if specific pools aren't implemented in this environment, we will still get back
          # at least the cluster or host we can pass on to the clone task
          # This catches if resource_pool option is set but comes back nil and if resourcePool is 
          # already set. 
          resource_pool ||= vm_mob_ref.resourcePool.nil? ? esx_host.parent.resourcePool : vm_mob_ref.resourcePool
                    
          # Options['datastore']<~String>
          # Grab the datastore object if option is set
          datastore_obj = get_raw_datastore(options['datastore'], options['datacenter']) if options.has_key?('datastore')
          # confirm nil if nil or option is not set
          datastore_obj ||= nil
          
          # Options['network']
          # Build up the config spec
          if ( options.has_key?('network_label') )
            #network_obj = datacenter_obj.networkFolder.find(options['network_label'])
            config_spec_operation = RbVmomi::VIM::VirtualDeviceConfigSpecOperation('edit')
            nic_backing_info = RbVmomi::VIM::VirtualEthernetCardNetworkBackingInfo(:deviceName => options['network_label'])
              #:deviceName => "Network adapter 1",
              #:network => network_obj)
            connectable = RbVmomi::VIM::VirtualDeviceConnectInfo(
              :allowGuestControl => true,
              :connected => true,
              :startConnected => true)
            device = RbVmomi::VIM::VirtualE1000(
              :backing => nic_backing_info,
              :deviceInfo => RbVmomi::VIM::Description(:label => "Network adapter 1", :summary => options['network_label']),
              :key => options['network_adapter_device_key'],
              :connectable => connectable)
            device_spec = RbVmomi::VIM::VirtualDeviceConfigSpec(
              :operation => config_spec_operation,
              :device => device)
            virtual_machine_config_spec = RbVmomi::VIM::VirtualMachineConfigSpec(
              :deviceChange => [device_spec])
          end
          
          # Options['customization_spec']
          # Build up all the crappy tiered objects like the perl method
          # Collect your variables ifset (writing at 11pm revist me)
          if ( options.has_key?('customization_spec') )
            cust_options = options['customization_spec']
            cust_domain = cust_options['domain']
            cust_hostname = RbVmomi::VIM::CustomizationFixedName.new(:name => cust_options['hostname']) if cust_options.has_key?('hostname')
            cust_hostname ||= RbVmomi::VIM::CustomizationFixedName.new(:name => options['name'])
            cust_hwclockutc = cust_options['hw_clock_utc']
            cust_timezone = cust_options['time_zone']
            # Start Building objects
            # Build the CustomizationLinuxPrep Object
            cust_prep = RbVmomi::VIM::CustomizationLinuxPrep.new(
              :domain => cust_domain,
              :hostName => cust_hostname,
              :hwClockUTC => cust_hwclockutc,
              :timeZone => cust_timezone)
            # Build the Dhcp Generator Object 
            cust_fixed_ip = RbVmomi::VIM::CustomizationDhcpIpGenerator.new()
            # Build the custom_ip_settings Object
            cust_ip_setting = RbVmomi::VIM::CustomizationIPSettings.new(:ip => cust_fixed_ip)
            # Build the Custom Adapter Mapping Supports only one eth right now
            cust_adapter_mapping = [RbVmomi::VIM::CustomizationAdapterMapping.new(:adapter => cust_ip_setting)]
            # Build the customization Spec
            customization_spec = RbVmomi::VIM::CustomizationSpec.new(
              :identity => cust_prep,
              :globalIPSettings => RbVmomi::VIM::CustomizationGlobalIPSettings.new(),
              :nicSettingMap => cust_adapter_mapping)
          end
          customization_spec ||= nil
          
          relocation_spec=nil
          if ( options['linked_clone'] )
            # cribbed heavily from the rbvmomi clone_vm.rb
            # this chunk of code reconfigures the disk of the clone source to be read only,
            # and then creates a delta disk on top of that, this is required by the API in order to create
            # linked clondes
            disks = vm_mob_ref.config.hardware.device.select do |vm_device|
              vm_device.class == RbVmomi::VIM::VirtualDisk
            end
            disks.select{|vm_device| vm_device.backing.parent == nil}.each do |disk|
              disk_spec = {
                :deviceChange => [
                  {
                    :operation => :remove,
                    :device => disk
                  },
                  {
                    :operation => :add,
                    :fileOperation => :create,
                    :device => disk.dup.tap{|disk_backing|
                      disk_backing.backing = disk_backing.backing.dup;
                      disk_backing.backing.fileName = "[#{disk.backing.datastore.name}]";
                      disk_backing.backing.parent = disk.backing
                    }
                  },
                ]
              }
              vm_mob_ref.ReconfigVM_Task(:spec => disk_spec).wait_for_completion
            end
            # Next, create a Relocation Spec instance
            relocation_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(:datastore => datastore_obj,
                                                                      :pool => resource_pool,
                                                                      :diskMoveType => :moveChildMostDiskBacking)
          else
            relocation_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(:datastore => datastore_obj, 
                                                                      :pool => resource_pool,
                                                                      :transform => options['transform'] || 'sparse')
          end
          # And the clone specification
          clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(:location => relocation_spec,
                                                            :config => virtual_machine_config_spec,
                                                            :customization => customization_spec,
                                                            :powerOn  => options.has_key?('power_on') ? options['power_on'] : true,
                                                            :template => false)
          
          # Perform the actual Clone Task
          task = vm_mob_ref.CloneVM_Task(:folder => dest_folder,
                                         :name => options['name'],
                                         :spec => clone_spec)
          # Waiting for the VM to complete allows us to get the VirtulMachine
          # object of the new machine when it's done.  It is HIGHLY recommended
          # to set 'wait' => true if your app wants to wait.  Otherwise, you're
          # going to have to reload the server model over and over which
          # generates a lot of time consuming API calls to vmware.
          if options['wait'] then
            # REVISIT: It would be awesome to call a block passed to this
            # request to notify the application how far along in the process we
            # are.  I'm thinking of updating a progress bar, etc...
            new_vm = task.wait_for_completion
          else
            tries = 0
            new_vm = begin
              # Try and find the new VM (folder.find is quite efficient)
              folder.find(options['name'], RbVmomi::VIM::VirtualMachine) or raise Fog::Vsphere::Errors::NotFound
            rescue Fog::Vsphere::Errors::NotFound
              tries += 1
              if tries <= 10 then
                sleep 15
                retry
              end
              nil
            end
          end
          
          # Return hash
          {
            'vm_ref'        => new_vm ? new_vm._ref : nil,
            'new_vm'        => new_vm ? get_virtual_machine("#{options['dest_folder']}/#{options['name']}", options['datacenter']) : nil,
            'task_ref'      => task._ref
          }
        end

      end

      class Mock
        include Shared
        def vm_clone(options = {})
          # Option handling TODO Needs better method of checking
          options = vm_clone_check_options(options)
          notfound = lambda { raise Fog::Compute::Vsphere::NotFound, "Could not find VM template" }
          list_virtual_machines.find(notfound) do |vm|
            vm[:name] == options['template_path'].split("/")[-1]
          end
          {
            'vm_ref'   => 'vm-123',
            'task_ref' => 'task-1234',
          }
        end

      end
    end
  end
end
