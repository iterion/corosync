#
# Cookbook Name:: corosync
# Recipe:: default
#
# Copyright 2012, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'base64'

# from https://github.com/mattray/barclamp_ha_service/blob/pacemaker_service/chef/cookbooks/pacemaker/recipes/master.rb

# install the corosync package
%w{openais corosync haveged}.each do |p|
  package p do
    action :install
  end
end

corosync_authkey = ""

# Find the authkey:
if !File.exists?("/etc/corosync/authkey")
  if Chef::Config[:solo]
    Chef::Application.fatal! "This recipe uses search. Chef Solo does not support search."
  else
    authkey = search(:node, "chef_environment:#{node.chef_environment} AND corosync:authkey")
    log("authkey contains #{authkey}")
    if authkey.length == 0
      # generate the auth key and then save it
      # create the auth key
      execute "corosync-keygen" do
        creates "/etc/corosync/authkey"
        user "root"
        group "root"
        umask "0400"
        action :run
      end
      # Read authkey (it's binary) into encoded format and save to chef server
      ruby_block "Store authkey" do
        block do
          file = File.new('/etc/corosync/authkey', 'r')
          contents = ""
          file.each do |f|
            contents << f
          end
          packed = Base64.encode64(contents)
          node.set_unless['corosync']['authkey'] = packed
          node.save
        end
        action :nothing
        subscribes :create, resources(:execute => "corosync-keygen"), :immediately
      end
    elsif authkey.length > 0
      log("Using corosync authkey from node: #{authkey[0].name}")

      # decode so we can write out to file below
      corosync_authkey = Base64.decode64(authkey[0]['corosync']['authkey'])

      file "/etc/corosync/authkey" do
        not_if {File.exists?("/etc/corosync/authkey")}
        content corosync_authkey
        owner "root"
        mode "0400"
        action :create
      end

      # set it to our own node hash so we can also be searched in future
      node.set['corosync']['authkey'] = authkey[0]['corosync']['authkey']
    end
  end
end

# TODO(breu): need the bindnetaddr for this node.
#             replace 192.168.0.0 below
# bindnetaddr = node.ipaddress[0..node.ipaddress.rindex('.')]+'0'

bindnetaddr = node['osops_networks']['management'].sub! /\/[0-9]+$/,''

template "/etc/corosync/corosync.conf" do
  source "corosync.conf.erb"
  owner "root"
  group "root"
  mode 0600
  variables(:bindnetaddr => bindnetaddr)
  notifies :restart, "service[corosync]", :delayed
end

template "/etc/default/corosync" do
  source "corosync.default.upstart.erb"
  owner "root"
  group "root"
  mode 0600
  variables(:enable_openais_service => node['corosync']['enable_openais_service'])
  notifies :restart, "service[corosync]", :delayed
end

directory "/etc/cluster" do
  owner "root"
  group "root"
  mode 0755
  action :create
  notifies :create, "template[/etc/cluster/cluster.conf]", :immediately
  only_if {node['corosync']['enable_openais_service'] == 'yes'}
end

template "/etc/cluster/cluster.conf" do
  source "cluster.conf.erb"
  owner "root"
  group "root"
  mode 0600
  variables(
    :node1 => node['corosync']['cluster']['node1'],
    :node2 => node['corosync']['cluster']['node2']
  )
  action :nothing
  notifies :restart, "service[corosync]", :delayed
  only_if {node['corosync']['enable_openais_service'] == 'yes'}
end

# This block is not really necessary because chef would automatically backup thie file.
# However, it's good to have the backup file in the same directory. (Easier to find later.)
ruby_block "backup corosync init script" do
  block do
      original_pathname = "/etc/init.d/corosync"
      backup_pathname = original_pathname + ".old"
      FileUtils.cp(original_pathname, backup_pathname, :preserve => true)
  end
  action :create
  notifies :create, "cookbook_file[/etc/init.d/corosync]", :immediately
  not_if "test -f /etc/init.d/corosync.old"
end

cookbook_file "/etc/init.d/corosync" do
  source "corosync.init"
  owner "root"
  group "root"
  mode 0755
  action :nothing
  notifies :restart, "service[corosync]", :immediately
end

service "corosync" do
  supports :restart => true, :status => :true
  action [:enable, :start]
end

