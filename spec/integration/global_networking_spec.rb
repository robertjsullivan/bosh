require 'spec_helper'

describe 'global networking', type: :integration do
  with_reset_sandbox_before_each

  before do
    target_and_login
    create_and_upload_test_release
    upload_stemcell
  end

  let(:cloud_config_hash) do
    cloud_config_hash = Bosh::Spec::Deployments.simple_cloud_config
    # remove size from resource pools due to bug #94220432
    # where resource pools with specified size reserve extra IPs
    cloud_config_hash['resource_pools'].first.delete('size')

    cloud_config_hash['networks'].first['subnets'].first['static'] =  ['192.168.1.10', '192.168.1.11']
    cloud_config_hash
  end

  let(:simple_manifest) do
    manifest_hash = Bosh::Spec::Deployments.simple_manifest
    manifest_hash['jobs'].first['instances'] = 1
    manifest_hash
  end

  let(:second_deployment_manifest) do
    manifest_hash = Bosh::Spec::Deployments.simple_manifest
    manifest_hash['jobs'].first['instances'] = 1
    manifest_hash['name'] = 'second_deployment'
    manifest_hash
  end

  def deploy_with_ip(manifest, ip, options={})
    deploy_with_ips(manifest, [ip], options)
  end

  def deploy_with_ips(manifest, ips, options={})
    manifest['jobs'].first['networks'].first['static_ips'] = ips
    manifest['jobs'].first['instances'] = ips.size
    options.merge!(manifest_hash: manifest)
    deploy_simple_manifest(options)
  end

  context 'when we have migrated to cloud config' do
    before do
      upload_cloud_config(cloud_config_hash: cloud_config_hash)
    end

    it 'deployments with shared manual network get next available IP from range' do
      deploy_simple_manifest(manifest_hash: simple_manifest)
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.2')

      deploy_simple_manifest(manifest_hash: second_deployment_manifest)
      second_deployment_vms = director.vms('second_deployment')
      expect(second_deployment_vms.size).to eq(1)
      expect(second_deployment_vms.first.ips).to eq('192.168.1.3')
    end

    it 'deployments on the same network can not use the same IP' do
      deploy_with_ip(simple_manifest, '192.168.1.10')
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.10')

      _, exit_code = deploy_with_ip(
        second_deployment_manifest,
        '192.168.1.10',
        { failure_expected: true, return_exit_code: true }
      )
      expect(exit_code).to_not eq(0)
    end

    it 'IPs used by one deployment can be used by another deployment after first deployment is deleted' do
      deploy_with_ip(simple_manifest, '192.168.1.10')
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.10')

      bosh_runner.run('delete deployment simple')

      deploy_with_ip(second_deployment_manifest, '192.168.1.10')
      second_deployment_vms = director.vms('second_deployment')
      expect(second_deployment_vms.size).to eq(1)
      expect(second_deployment_vms.first.ips).to eq('192.168.1.10')
    end

    it 'IPs released by one deployment via scaling down can be used by another deployment' do
      deploy_with_ips(simple_manifest, ['192.168.1.10', '192.168.1.11'])
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(2)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.10')
      expect(first_deployment_vms[1].ips).to eq('192.168.1.11')

      simple_manifest['jobs'].first['instances'] = 0
      simple_manifest['jobs'].first['networks'].first['static_ips'] = []


      current_sandbox.cpi.commands.pause_delete_vms
      deploy_simple_manifest(manifest_hash: simple_manifest, no_track: true)

      current_sandbox.cpi.commands.wait_for_delete_vms
      _, exit_code = deploy_with_ips(
        second_deployment_manifest,
        ['192.168.1.10', '192.168.1.11'],
        { failure_expected: true, return_exit_code: true }
      )
      expect(exit_code).to_not eq(0)

      current_sandbox.cpi.commands.unpause_delete_vms

      puts bosh_runner.run('task latest --debug')

      deploy_with_ips(second_deployment_manifest, ['192.168.1.10', '192.168.1.11'])
      second_deployment_vms = director.vms('second_deployment')
      expect(second_deployment_vms.size).to eq(2)
      expect(second_deployment_vms.first.ips).to eq('192.168.1.10')
      expect(second_deployment_vms[1].ips).to eq('192.168.1.11')
    end

    it 'IPs released by one deployment via changing IP can be used by another deployment' do
      deploy_with_ip(simple_manifest, '192.168.1.10')
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.10')

      deploy_with_ip(simple_manifest, '192.168.1.11')
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.11')

      deploy_with_ip(second_deployment_manifest, '192.168.1.10')
      second_deployment_vms = director.vms('second_deployment')
      expect(second_deployment_vms.size).to eq(1)
      expect(second_deployment_vms.first.ips).to eq('192.168.1.10')
    end

    it 'IP is still reserved when vm is recreated due to network changes other than IP address' do
      deploy_with_ip(simple_manifest, '192.168.1.10')
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.10')

      cloud_config_hash['networks'].first['subnets'].first['gateway'] = '192.168.1.15'
      upload_cloud_config(cloud_config_hash: cloud_config_hash)
      deploy_with_ip(simple_manifest, '192.168.1.10')

      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.10')

      _, exit_code = deploy_with_ip(
        second_deployment_manifest,
        '192.168.1.10',
        { failure_expected: true, return_exit_code: true }
      )
      expect(exit_code).to_not eq(0)
    end

    it 'redeploys VM on new IP address when reserved list includes current IP address of VM' do
      deploy_simple_manifest(manifest_hash: simple_manifest)
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.2')

      cloud_config_hash['networks'].first['subnets'].first['reserved'] = ['192.168.1.2']
      upload_cloud_config(cloud_config_hash: cloud_config_hash)

      deploy_simple_manifest(manifest_hash: simple_manifest)
      first_deployment_vms = director.vms
      expect(first_deployment_vms.size).to eq(1)
      expect(first_deployment_vms.first.ips).to eq('192.168.1.3')
    end
  end

  context 'when we have not yet migrated to cloud config' do
    let(:legacy_manifest) do
      legacy_manifest = Bosh::Spec::Deployments.legacy_manifest
      legacy_manifest['jobs'].first['instances'] = 1
      legacy_manifest['resource_pools'].first.delete('size')
      legacy_manifest
    end

    context 'with ressurector' do
      before { current_sandbox.health_monitor_process.start }
      after { current_sandbox.health_monitor_process.stop }

      it 'ressurects vms with old deployment ignoring cloud config' do
        deploy_simple_manifest(manifest_hash: legacy_manifest)
        vms = director.vms
        expect(vms.size).to eq(1)
        expect(vms.first.ips).to eq('192.168.1.2')

        cloud_config_hash['networks'].first['subnets'].first['reserved'] = ['192.168.1.2']
        upload_cloud_config(cloud_config_hash: cloud_config_hash)

        original_vm = director.vm('foobar/0')
        original_vm.kill_agent
        resurrected_vm = director.wait_for_vm('foobar/0', 300)
        expect(resurrected_vm.cid).to_not eq(original_vm.cid)
        vms = director.vms
        expect(vms.size).to eq(1)
        expect(vms.first.ips).to eq('192.168.1.2')
      end
    end

    context 'without ressurector' do
      it 'deployment after cloud config gets IP outside of range reserved by first deployment' do
        legacy_manifest['networks'].first['subnets'].first['range'] = '192.168.1.0/28'
        deploy_simple_manifest(manifest_hash: legacy_manifest)
        vms = director.vms
        expect(vms.size).to eq(1)
        expect(vms.first.ips).to eq('192.168.1.2')

        upload_cloud_config(cloud_config_hash: cloud_config_hash)

        deploy_simple_manifest(manifest_hash: second_deployment_manifest)
        vms = director.vms
        expect(vms.size).to eq(1)
        expect(vms.first.ips).to eq('192.168.1.16')
      end

      it 'deployment after cloud config fails to get static IP in the range reserved by first deployment' do
        legacy_manifest['networks'].first['subnets'].first['range'] = '192.168.1.0/28'
        deploy_simple_manifest(manifest_hash: legacy_manifest)
        vms = director.vms
        expect(vms.size).to eq(1)
        expect(vms.first.ips).to eq('192.168.1.2')

        upload_cloud_config(cloud_config_hash: cloud_config_hash)

        _, exit_code = deploy_with_ip(
          second_deployment_manifest,
          '192.168.1.2',
          { failure_expected: true, return_exit_code: true }
        )
        expect(exit_code).to_not eq(0)
      end
    end
  end
end