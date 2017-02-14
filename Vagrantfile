VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.define "openresty" do |server|
    server.vm.hostname = "openresty"
    server.vm.box = "ubuntu/trusty64"
    server.vm.provider :virtualbox do |vb|
      vb.customize ["modifyvm", :id, "--memory", "1024"]
    end
  end
end
