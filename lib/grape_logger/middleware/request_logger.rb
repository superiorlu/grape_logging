module GrapeLogger
  module Middleware
    # :nodoc:
    class RequestLogger < Grape::Middleware::Globals
      if defined?(ActiveRecord)
        ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          GrapeLogger::Timings.append_db_runtime(event)
        end
      end

      def initialize(app, options = {})
        super
        @included_loggers = options[:include] || []
        @reporter = Reporters::LoggerReporter.new(options[:logger], options[:formatter])
        if options[:instrument_key]
          @active_support_reporter = Reporters::ActiveSupportReporter.new(options[:instrument_key])
        end
        @status = nil
      end

      def before
        super
        reset_db_runtime
        set_request_id
        start_time
        @reporter.info "#{request.request_method} #{request.path} #{request_params}"

        invoke_included_loggers(:before)
      end

      def after
        stop_time
        params = collect_parameters
        @reporter.perform(params)
        @active_support_reporter.perform(params) if @active_support_reporter
        invoke_included_loggers(:after)
        nil
      end

      def call!(env)
        @env = env
        before
        error = catch(:error) do
          begin
            @app_response = @app.call(@env)
          rescue => e
            @status = 500
            @reporter.error e
            raise e
          end
          nil
        end
        if error
          @status = error[:status]
          throw(:error, error)
        else
          @status, = *@app_response
        end
        @app_response
      ensure
        after
      end

      protected

      def parameters
        {
          status: @status,
          time: {
            total: total_runtime,
            db: db_runtime,
            view: view_runtime
          }
        }
      end

      private

      def request_params
        request_params = env[Grape::Env::GRAPE_REQUEST_PARAMS].to_h
        request_params.merge! env[Grape::Env::RACK_REQUEST_FORM_HASH] if env[Grape::Env::RACK_REQUEST_FORM_HASH]
        request_params.merge! env['action_dispatch.request.request_parameters'] if env['action_dispatch.request.request_parameters']
        request_params
      end

      def set_request_id
        Thread.current[:request_id] = request.object_id
      end

      def request
        @request ||= env[Grape::Env::GRAPE_REQUEST]
      end

      def total_runtime
        ((stop_time - start_time) * 1000).round(2)
      end

      def view_runtime
        (total_runtime - db_runtime).round(2)
      end

      def db_runtime
        GrapeLogger::Timings.db_runtime.round(2)
      end

      def reset_db_runtime
        GrapeLogger::Timings.reset_db_runtime
      end

      def start_time
        @start_time ||= Time.now
      end

      def stop_time
        @stop_time ||= Time.now
      end

      def collect_parameters
        parameters.tap do |params|
          @included_loggers.each do |logger|
            params.merge! logger.parameters(request, response) do |_, oldval, newval|
              oldval.respond_to?(:merge) ? oldval.merge(newval) : newval
            end
          end
        end
      end

      def invoke_included_loggers(method_name)
        @included_loggers.each do |logger|
          logger.send(method_name) if logger.respond_to?(method_name)
        end
      end
    end
  end
end
