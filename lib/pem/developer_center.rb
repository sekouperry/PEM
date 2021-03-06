require 'credentials_manager/password_manager'
require 'open-uri'
require 'openssl'

require 'capybara'
require 'capybara/poltergeist'

module PEM
  class DeveloperCenter
    # This error occurs only if there is something wrong with the given login data
    class DeveloperCenterLoginError < StandardError 
    end

    # This error can occur for many reaons. It is
    # usually raised when a UI element could not be found
    class DeveloperCenterGeneralError < StandardError
    end

    include Capybara::DSL

    DEVELOPER_CENTER_URL = "https://developer.apple.com/devcenter/ios/index.action"
    APP_IDS_URL = "https://developer.apple.com/account/ios/identifiers/bundle/bundleList.action"

    # Strings
    PRODUCTION_SSL_CERTIFICATE_TITLE = "Production SSL Certificate"
    DEVELOPMENT_SSL_CERTIFICATE_TITLE = "Development SSL Certificate"

    def initialize
      FileUtils.mkdir_p TMP_FOLDER
      
      Capybara.run_server = false
      Capybara.default_driver = :poltergeist
      Capybara.javascript_driver = :poltergeist
      Capybara.current_driver = :poltergeist
      Capybara.app_host = DEVELOPER_CENTER_URL

      # Since Apple has some SSL errors, we have to configure the client properly:
      # https://github.com/ariya/phantomjs/issues/11239
      Capybara.register_driver :poltergeist do |a|
        conf = ['--debug=no', '--ignore-ssl-errors=yes', '--ssl-protocol=TLSv1']
        Capybara::Poltergeist::Driver.new(a, {
          phantomjs_options: conf,
          phantomjs_logger: File.open("#{TMP_FOLDER}/poltergeist_log.txt", "a"),
          js_errors: false
        })
      end

      page.driver.headers = { "Accept-Language" => "en" }

      self.login
    end

    # Loggs in a user with the given login data on the Dev Center Frontend.
    # You don't need to pass a username and password. It will
    # Automatically be fetched using the {CredentialsManager::PasswordManager}.
    # This method will also automatically be called when triggering other 
    # actions like {#open_app_page}
    # @param user (String) (optional) The username/email address
    # @param password (String) (optional) The password
    # @return (bool) true if everything worked fine
    # @raise [DeveloperCenterGeneralError] General error while executing 
    #  this action
    # @raise [DeveloperCenterLoginError] Login data is wrong
    def login(user = nil, password = nil)
      begin
        Helper.log.info "Login into iOS Developer Center"

        user ||= CredentialsManager::PasswordManager.shared_manager.username
        password ||= CredentialsManager::PasswordManager.shared_manager.password

        result = visit DEVELOPER_CENTER_URL
        raise "Could not open Developer Center" unless result['status'] == 'success'

        wait_for_elements(".button.blue").first.click

        (wait_for_elements('#accountpassword') rescue nil) # when the user is already logged in, this will raise an exception

        if page.has_content?"My Apps"
          # Already logged in
          return true
        end

        fill_in "accountname", with: user
        fill_in "accountpassword", with: password
        
        all(".button.large.blue.signin-button").first.click

        begin
          if page.has_content?"Select Your Team" # If the user is not on multiple teams
            team_id = ENV["PEM_TEAM_ID"]
            unless team_id
              Helper.log.info "You can store you preferred team using the environment variable `PEM_TEAM_ID`".green
              Helper.log.info "Your ID belongs to the following teams:".green
              
              teams = find("select").all('option') # Grab all the teams data
              teams.each_with_index do |val, index|
                team_text = val.text
                description_text = val.value
                description_text = " (#{description_text})" unless description_text.empty? # Include the team description if any
                Helper.log.info "\t#{index + 1}. #{team_text}#{description_text}".green # Print the team index and team name
              end
              
              team_index = ask("Please select the team number you would like to access: ".green)
              team_id = teams[team_index.to_i - 1].value # Select the desired team
            end
          within 'select' do
            find("option[value='#{team_id}']").select_option
          end
            
         all("#saveTeamSelection_saveTeamSelection").first.click
         end
        rescue => ex
          Helper.log.debug ex
          raise DeveloperCenterLoginError.new("Error loggin in user #{user}. User is on multiple teams and we were unable to correctly retrieve them.")
        end

        begin
          
          wait_for_elements('#aprerelease')
        rescue => ex
          Helper.log.debug ex
          raise DeveloperCenterLoginError.new("Error logging in user #{user} with the given password. Make sure you entered them correctly.")
        end

        Helper.log.info "Login successful"

        true
      rescue => ex
        error_occured(ex)
      end
    end

    # This method will enable push for the given app
    # and download the cer file in any case, no matter if it existed before or not
    # @return the path to the push file
    def fetch_cer_file(app_identifier, production)
      begin
        open_app_page(app_identifier)

        click_on "Edit"
        wait_for_elements(".item-details") # just to finish loading

        push_value = first(:css, '#pushEnabled').value
        if push_value == "on"
          Helper.log.info "Push for app '#{app_identifier}' is enabled"
        else
          Helper.log.warn "Push for app '#{app_identifier}' is disabled. This has to change."
          first(:css, '#pushEnabled').click
        end

        Helper.log.warn "Creating push certificate for app '#{app_identifier}'."
        create_push_for_app(app_identifier, production)
      rescue => ex
        error_occured(ex)
      end
    end


    private
      def open_app_page(app_identifier)
        begin
          visit APP_IDS_URL

          apps = all(:xpath, "//td[@title='#{app_identifier}']")
          if apps.count == 1
            apps.first.click
            sleep 1

            return true
          else
            raise DeveloperCenterGeneralError.new("Could not find app with identifier '#{app_identifier}' on apps page.")
          end
        rescue => ex
          error_occured(ex)
        end
      end

      def create_push_for_app(app_identifier, production)
        element_name = (production ? '.button.small.navLink.distribution.enabled' : '.button.small.navLink.development.enabled')
        begin
          wait_for_elements(element_name).first.click # Create Certificate button
        rescue
          raise "Could not create a new push profile for app '#{app_identifier}'. There are already 2 certificates active. Please revoke one to let PEM create a new one\n\n#{current_url}".red
        end

        sleep 2

        click_next # "Continue"

        sleep 1
        wait_for_elements(".file-input.validate")
        wait_for_elements(".button.small.center.back")

        # Upload CSR file
        first(:xpath, "//input[@type='file']").set PEM::SigningRequest.get_path

        click_next # "Generate"

        while all(:css, '.loadingMessage').count > 0
          Helper.log.debug "Waiting for iTC to generate the profile"
          sleep 2
        end

        certificate_type = (production ? 'production' : 'development')

        # Download the newly created certificate
        Helper.log.info "Going to download the latest profile"

        # It is enabled, now just download it
        sleep 2

        download_button = first(".button.small.blue")
        host = Capybara.current_session.current_host
        url = download_button['href']
        url = [host, url].join('')
        Helper.log.info "Downloading URL: '#{url}'"
        
        cookieString = ""
        
        page.driver.cookies.each do |key, cookie|
          cookieString << "#{cookie.name}=#{cookie.value};" # append all known cookies
        end  
        
        data = open(url, {'Cookie' => cookieString}).read

        raise "Something went wrong when downloading the certificate" unless data

        path = "#{TMP_FOLDER}aps_#{certificate_type}_#{app_identifier}.cer"
        dataWritten = File.write(path, data)
        
        if dataWritten == 0
          raise "Can't write to #{TMP_FOLDER}"
        end
        
        Helper.log.info "Successfully downloaded latest .cer file."
        return path
      end


    private
      def click_next
        wait_for_elements('.button.small.blue.right.submit').last.click
      end

      def error_occured(ex)
        snap
        raise ex # re-raise the error after saving the snapshot
      end

      def snap
        path = "Error#{Time.now.to_i}.png"
        save_screenshot(path, :full => true)
        system("open '#{path}'")
      end

      def wait_for_elements(name)
        counter = 0
        results = all(name)
        while results.count == 0      
          # Helper.log.debug "Waiting for #{name}"
          sleep 0.2

          results = all(name)

          counter += 1
          if counter > 100
            Helper.log.debug page.html
            Helper.log.debug caller
            raise DeveloperCenterGeneralError.new("Couldn't find element '#{name}' after waiting for quite some time")
          end
        end
        return results
      end
  end
end
