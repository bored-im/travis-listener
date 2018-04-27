require 'sinatra'
require 'travis/support/logging'
require 'sidekiq'
require 'travis/sidekiq'
require 'oj'
require 'ipaddr'

module Travis
  module Listener
    class App < Sinatra::Base
      include Logging

      # use Rack::CommonLogger for request logging
      enable :logging, :dump_errors

      # see https://github.com/github/github-services/blob/master/lib/services/travis.rb#L1-2
      # https://github.com/travis-ci/travis-api/blob/255640fd4f191f1de6951081f0c5848324210fb5/lib/travis/github/services/set_hook.rb#L8
      # https://github.com/travis-ci/travis-api/blob/255640fd4f191f1de6951081f0c5848324210fb5/lib/travis/api/v3/github.rb#L41
      set :events, %w[
        push
        pull_request
        create
        delete
        repository
        installation
        installation_repositories
      ]

      before do
        logger.level = 1
      end

      get '/' do
        redirect "http://travis-ci.com"
      end

      # Used for new relic uptime monitoring
      get '/uptime' do
        200
      end

      # the main endpoint for scm services
      post '/' do
        report_ip_validity
        if !ip_validation? || valid_ip?
          if valid_request?
            dispatch_event

            204
          else
            Listener.metrics.meter('listener.request.no_payload')

            422
          end
        else
          403
        end
      end

      protected

      def valid_request?
        payload
      end

      def ip_validation?
        (Travis.config.listener && Travis.config.listener.ip_validation)
      end

      def report_ip_validity
        if valid_ip?
          Listener.metrics.meter('listener.ip.valid')
        else
          Listener.metrics.meter('listener.ip.invalid')
          logger.info "Payload to travis-listener sent from an invalid IP(#{request.ip})"
        end
      end

      def valid_ip?
        return true if valid_ips.empty?

        valid_ips.any? { |ip| IPAddr.new(ip).include? request.ip }
      end

      def valid_ips
        (Travis.config.listener && Travis.config.listener.valid_ips) || []
      end

      def dispatch_event
        return unless handle_event?
        debug "Event payload for #{uuid}: #{payload.inspect}"

        if github_pr_event?
          gatekeeper_event
        elsif github_apps_event?
          sync_event
        end
      end

      def github_pr_event?
        [
          'push',
          'pull_request',
          'create',
          'delete',
          'repository',
        ].include? event_type
      end

      def github_apps_event?
        [
          'installation',
          'installation_repositories',
        ].include? event_type
      end

      def gatekeeper_event
        log_event(
          event_details,
          uuid:          uuid,
          delivery_guid: delivery_guid,
          type:          event_type,
          repository:    slug
        )

        Listener.metrics.meter("listener.event.webhook_#{event_type}")

        Travis::Sidekiq::Gatekeeper.push(Travis.config.gator.queue, data)
      end

      def sync_event
        log_event(
          event_details,
          uuid:          uuid,
          delivery_guid: delivery_guid,
          type:          event_type
        )

        case event_type
        when 'installation'
          Travis::Sidekiq::GithubSync.gh_app_install(data)
        when 'installation_repositories'
          Travis::Sidekiq::GithubSync.gh_app_repos(data)
        else
          logger.info "Unable to find a sync event for event_type: #{event_type}"
          false
        end
      end

      def handle_event?
        settings.events.include?(event_type)
      end

      def log_event(event_details, event_basics)
        info(event_basics.merge(event_details).map{|k,v| "#{k}=#{v}"}.join(" "))
      end

      def data
        {
          :type         => event_type,
          :payload      => payload,
          :uuid         => uuid,
          :github_guid  => delivery_guid,
          :github_event => event_type,
        }
      end

      def uuid
        env['HTTP_X_REQUEST_ID'] || Travis.uuid
      end

      def event_type
        env['HTTP_X_GITHUB_EVENT'] || 'push'
      end

      def event_details
        if event_type == 'pull_request'
          {
            number: decoded_payload['number'],
            action: decoded_payload['action'],
            source: decoded_payload['pull_request']['head']['repo'] && decoded_payload['pull_request']['head']['repo']['full_name'],
            head:   decoded_payload['pull_request']['head']['sha'][0..6],
            ref:    decoded_payload['pull_request']['head']['ref'],
            user:   decoded_payload['pull_request']['user']['login'],
          }
        elsif event_type == 'push'
          {
            ref:     decoded_payload['ref'],
            head:    push_head_commit,
            commits: (decoded_payload["commits"] || []).map {|c| c['id'][0..6]}.join(",")
          }
        else
          {}
        end
      rescue => e
        error("Error logging payload: #{e.message}")
        error("Payload causing error: #{decoded_payload}")
        Raven.capture_exception(e)
        {}
      end

      def push_head_commit
        decoded_payload['head_commit'] && decoded_payload['head_commit']['id'] && decoded_payload['head_commit']['id'][0..6]
      end

      def delivery_guid
        env['HTTP_X_GITHUB_GUID'] || env['HTTP_X_GITHUB_DELIVERY']
      end

      def payload
        if !params[:payload].blank?
          params[:payload]
        elsif !request_body.blank?
          request_body
        else
          nil
        end
      end

      def request_body
        @_request_body ||= begin
          request.body.rewind
          request.body.read.force_encoding("utf-8")
        end
      end

      def slug
        "#{owner_login}/#{repository_name}"
      end

      def owner_login
        owner['login'] || owner['name']
      end

      def owner
        decoded_payload['repository'] && decoded_payload['repository']['owner'] || {}
      end

      def repository_name
        decoded_payload['repository']['name']
      end

      def decoded_payload
        @decoded_payload ||= Oj.load(payload)
      end
    end
  end
end
