module Match
  class Runner
    attr_accessor :changes_to_commit

    def run(params)
      FastlaneCore::PrintTable.print_values(config: params,
                                         hide_keys: [:workspace],
                                             title: "Summary for match #{Match::VERSION}")

      params[:workspace] = GitHelper.clone(params[:git_url], params[:shallow_clone], skip_docs: params[:skip_docs], branch: params[:git_branch])
      spaceship = SpaceshipEnsure.new(params[:username]) unless params[:readonly]

      # Verify the App ID (as we don't want 'match' to fail at a later point)
      spaceship.bundle_identifier_exists(params) if spaceship

      # Certificate
      cert_id = certificate(params: params)
      spaceship.certificate_exists(params, cert_id) if spaceship

      selected_profile = nil
      # Provisioning Profile
      if params[:use_existing]
        UI.important "test"
        type_map = {'development' => 'iOS Development','adhoc' => 'iOS Distribution', 'appstore' => 'iOS Distribution'}
        distribution_map = {'development' => 'limited','adhoc' => 'adhoc', 'appstore' => 'store'}
        all_profiles = Spaceship.provisioning_profile.all
        selected_profile = all_profiles.find do |pfile| 
          UI.important type_map[params[:type]]
          UI.important distribution_map[params[:type]]
          pfile.app.bundle_id == params[:app_identifier] && pfile.type == type_map[params[:type]] && pfile.distribution_method == distribution_map[params[:type]]
        end
      end

      if selected_profile
        puts "selected_profile :: #{selected_profile.name}"
        certificate = Spaceship.certificate.all.find {|cert| cert.id == cert_id }
        selected_profile.certificates = [certificate]
        selected_profile = selected_profile.update!
        output_path = File.join(params[:workspace], "profiles", params[:type].to_s,"#{Match::Generator.profile_type_name(params[:type].to_sym)}_#{params[:app_identifier]}.mobileprovision")
        puts "output_path :: #{output_path}"
        require 'fileutils'
        dirpath = File.dirname(output_path)
        FileUtils::mkdir_p dirpath
        profile_data = selected_profile.download
        File.open(output_path, 'w') { |file| file.write(profile_data) }
        self.changes_to_commit = true
      else
        uuid = profile(params: params,
                     certificate_id: cert_id)
        spaceship.profile_exists(params, uuid) if spaceship
      end
        

      # Done
      if self.changes_to_commit and !params[:readonly]
        message = GitHelper.generate_commit_message(params)
        GitHelper.commit_changes(params[:workspace], message, params[:git_url], params[:git_branch])
      end

      TablePrinter.print_summary(params, uuid)

      UI.success "All required keys, certificates and provisioning profiles are installed 🙌".green
    ensure
      GitHelper.clear_changes
    end

    def certificate(params: nil)
      cert_type = :distribution
      cert_type = :development if params[:type] == "development"
      cert_type = :enterprise if Match.enterprise? && params[:type] == "enterprise"

      certs = Dir[File.join(params[:workspace], "certs", cert_type.to_s, "*.cer")]
      keys = Dir[File.join(params[:workspace], "certs", cert_type.to_s, "*.p12")]

      if certs.count == 0 or keys.count == 0
        UI.important "Couldn't find a valid code signing identity in the git repo for #{cert_type}... creating one for you now"
        UI.crash!("No code signing identity found and can not create a new one because you enabled `readonly`") if params[:readonly]
        cert_path = Generator.generate_certificate(params, cert_type)
        self.changes_to_commit = true
      else
        cert_path = certs.last
        UI.message "Installing certificate..."

        if FastlaneCore::CertChecker.installed?(cert_path)
          UI.verbose "Certificate '#{File.basename(cert_path)}' is already installed on this machine"
        else
          Utils.import(cert_path, params[:keychain_name])
        end

        # Import the private key
        # there seems to be no good way to check if it's already installed - so just install it
        Utils.import(keys.last, params[:keychain_name])
      end

      return File.basename(cert_path).gsub(".cer", "") # Certificate ID
    end

    def profile(params: nil, certificate_id: nil)
      prov_type = params[:type].to_sym

      profile_name = [Match::Generator.profile_type_name(prov_type), params[:app_identifier]].join("_").gsub("*", '\*') # this is important, as it shouldn't be a wildcard
      profiles = Dir[File.join(params[:workspace], "profiles", prov_type.to_s, "#{profile_name}.mobileprovision")]

      # Install the provisioning profiles
      profile = profiles.last

      if params[:force_for_new_devices] && !params[:readonly]
        params[:force] = device_count_different?(profile: profile) unless params[:force]
      end

      if profile.nil? or params[:force]
        UI.user_error!("No matching provisioning profiles found and can not create a new one because you enabled `readonly`") if params[:readonly]
        profile = Generator.generate_provisioning_profile(params: params,
                                                       prov_type: prov_type,
                                                  certificate_id: certificate_id)
        self.changes_to_commit = true
      end

      FastlaneCore::ProvisioningProfile.install(profile)

      parsed = FastlaneCore::ProvisioningProfile.parse(profile)
      uuid = parsed["UUID"]
      Utils.fill_environment(params, uuid)

      return uuid
    end

    def device_count_different?(profile: nil)
      if profile
        parsed = FastlaneCore::ProvisioningProfile.parse(profile)
        uuid = parsed["UUID"]
        portal_profile = Spaceship.provisioning_profile.all.detect { |i| i.uuid == uuid }

        if portal_profile
          profile_device_count = portal_profile.devices.count
          portal_device_count = Spaceship.device.all.count
          return portal_device_count != profile_device_count
        end
      end
      return false
    end
  end
end
