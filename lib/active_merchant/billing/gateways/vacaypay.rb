module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class VacaypayGateway < Gateway
      self.money_format = :dollars

      # Since we call two different API's we differentiate the response and method handling based on the action
      # eg tokenize will go to Stripe so we send the action parameter to the required methods to determine how
      # to handle the data

      class_attribute :live_url_stripe
      self.live_url_stripe = 'https://api.stripe.com/v1/'
      self.live_url = 'https://www.procuro.io/api/v1/'

      self.supported_countries = %w(AU CA GB US BE DK FI FR DE NL NO ES IT IE)
      self.default_currency = 'USD'
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb, :diners_club, :maestro]
      self.homepage_url = 'https://www.procuro.io/'
      self.display_name = 'VacayPay'

      STANDARD_ERROR_CODE_MAPPING = {
          'incorrect_number' => STANDARD_ERROR_CODE[:incorrect_number],
          'invalid_number' => STANDARD_ERROR_CODE[:invalid_number],
          'invalid_expiry_month' => STANDARD_ERROR_CODE[:invalid_expiry_date],
          'invalid_expiry_year' => STANDARD_ERROR_CODE[:invalid_expiry_date],
          'invalid_cvc' => STANDARD_ERROR_CODE[:invalid_cvc],
          'expired_card' => STANDARD_ERROR_CODE[:expired_card],
          'incorrect_cvc' => STANDARD_ERROR_CODE[:incorrect_cvc],
          'incorrect_zip' => STANDARD_ERROR_CODE[:incorrect_zip],
          'card_declined' => STANDARD_ERROR_CODE[:card_declined],
          'call_issuer' => STANDARD_ERROR_CODE[:call_issuer],
          'processing_error' => STANDARD_ERROR_CODE[:processing_error],
          'incorrect_pin' => STANDARD_ERROR_CODE[:incorrect_pin],
          'test_mode_live_card' => STANDARD_ERROR_CODE[:test_mode_live_card]
      }

      def initialize(options={})
        super
        requires!(options, :api_key, :account_uuid)

        @api_key = options[:api_key]
        @account_uuid = options.key?(:account_uuid) ? options[:account_uuid] : nil
        @publishable_key = options.key?(:publishable_key) ? options[:publishable_key] : nil
      end

      def headers(action)
        if action == 'tokenize'
          {
              'Authorization' => 'Bearer ' + @publishable_key.to_s,
              'Content-Type' => 'application/x-www-form-urlencoded'
          }
        else
          {
              'X-Auth-Token' => @api_key.to_s,
              'Content-Type' => 'application/json'
          }
        end
      end

      def clear_publishable_key
        @account_uuid = ''
      end

      def get_publishable_key
        @account_uuid
      end

      def fetch_publishable_key_if_empty
        if @publishable_key.nil? || @publishable_key.to_s.empty? || @publishable_key === 'nil'
          fetch_account_details
        end
      end

      def fetch_account_details
        begin
          url = determine_full_url('account_details', {})
          response = parse(ssl_get(url, headers('account_details')))
          @publishable_key = response['data']['publishableKey']
        rescue ResponseError
          # Not authentication part just fetching extra details - wait till we get the 401 if credentials invalid
        end
      end

      def tokenize(payment_method, options={})
        fetch_publishable_key_if_empty

        card = {}
        card[:number] = payment_method.number
        card[:cvc] = payment_method.verification_value
        card[:exp_month] = format(payment_method.month, :two_digits)
        card[:exp_year] = format(payment_method.year, :two_digits)

        commit('tokenize', {
            :card => card
        })
      end

      def purchase(money, payment_method, options={})
        post = {}

        token_response = tokenize(payment_method, options)

        unless token_response.success?
          return token_response
        end

        add_payment_method(post, token_response)
        add_invoice(post, money, options)
        add_address(post, payment_method, options)
        add_customer_data(post, options)
        add_settings(post, options)

        commit('charge', post)
      end

      def authorize(money, payment_method, options={})
        post = {}

        token_response = tokenize(payment_method, options)

        unless token_response.success?
          return token_response
        end

        add_payment_method(post, token_response)
        add_invoice(post, money, options)
        add_address(post, payment_method, options)
        add_customer_data(post, options)
        add_settings(post, options)

        post[:authorize] = true

        commit('authorize', post)
      end

      def capture(money, authorization, options={})
        options[:payment_uuid] = authorization
        options[:amount] = amount(money)

        commit('capture', options)
      end

      def refund(money, authorization, options={})
        options[:payment_uuid] = authorization
        options[:amount] = amount(money)

        commit('refund', options)
      end

      def void(authorization, options={})
        options[:payment_uuid] = authorization

        commit('void', options)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
            gsub(%r(((?:\r\n)?X-Auth-Token: )[^\\]*), '\1[FILTERED]').
            gsub(%r("number\\?":\\?"[0-9]*\\?"), '\1[FILTERED]').
            gsub(%r("cvv\\?":\\?"[0-9]*\\?"), '\1[FILTERED]').
            gsub(%r((Authorization: Basic )\w+), '\1[FILTERED]').
            gsub(%r((Authorization: Bearer )\w+), '\1[FILTERED]').
            gsub(%r((card\[number\]=)\d+), '\1[FILTERED]').
            gsub(%r((card\[cvc\]=)\d+), '\1[FILTERED]')
      end

      def add_customer_data(post, options)
        post[:email] = options[:email] || ''
        post[:firstName] = options[:firstName] || ''
        post[:lastName] = options[:lastName] || ''
        post[:description] = options[:description] || ''
        post[:externalPaymentReference] = options[:externalPaymentReference] || ''
        post[:externalBookingReference] = options[:externalBookingReference] || ''
        post[:accessingIp] = options[:accessingIp] || nil
        post[:notes] = options[:notes] || ''
        post[:metadata] = options[:metadata] || {}
      end

      def add_address(post, creditcard, options)
        address = options[:billing_address] || options[:address]
        if address
          post[:billingLine1] = address[:address1] if address[:address1]
          post[:billingLine2] = address[:address2] if address[:address2]
          post[:billingPostcode] = address[:zip] if address[:zip]
          post[:billingRegion] = address[:state] if address[:state]
          post[:billingCity] = address[:city] if address[:city]
          post[:billingCountry] = address[:country] if address[:country]
        end
      end

      def add_invoice(post, money, options)
        post[:amount] = amount(money)
        post[:currency] = (options[:currency] || currency(money))
      end

      def add_payment_method(post, token_response)
        post[:cardToken] = token_response.authorization
      end

      def add_settings(post, options)
        post[:sendEmailConfirmation] = options[:sendEmailConfirmation] # Defaults to false
      end

      def parse(body)
        if body.nil?
          {}
        else
          JSON.parse(body)
        end
      end

      def commit(action, parameters)
        url = determine_full_url(action, parameters)

        begin
          raw_response = ssl_post(url, post_data(action, parameters), headers(action))
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = parse(raw_response)
        end

        succeeded = success_from(action, response)

        Response.new(
            succeeded,
            message_from(action, succeeded, response),
            response,
            authorization: authorization_from(action, response),
            test: test?,
            error_code: error_code_from(action, response)
        )
      end

      def determine_full_url(action, parameters)
        # Set uuid to 0 as we get a route not found (404) when account_uuid empty - this will return the expected 401
        account_uuid = @account_uuid.to_s.empty? ? '0' : @account_uuid.to_s

        if action == 'charge' || action == 'authorize'
          endpoint = "#{self.live_url}vacay-pay/accounts/#{account_uuid}/payments"
        elsif action == 'capture'
          endpoint = "#{self.live_url}vacay-pay/accounts/#{account_uuid}/payments/#{parameters[:payment_uuid]}/capture"
        elsif action == 'refund' || action == 'void'
          endpoint = "#{self.live_url}vacay-pay/accounts/#{account_uuid}/payments/#{parameters[:payment_uuid]}/refund"
        elsif action =='account_details'
          endpoint = "#{self.live_url}vacay-pay/accounts/#{account_uuid}"
        elsif action == 'tokenize'
          endpoint = "#{self.live_url_stripe}tokens"
        else
          raise ActiveMerchantError.new('Cannot commit without a valid endpoint')
        end

        endpoint
      end

      def success_from(action, response)
        if action == 'tokenize'
          !response.key?('error')
        else
          response['appCode'] == 0;
        end
      end

      def message_from(action, succeeded, response)
        if succeeded
          message = 'Succeeded'
        else
          if action == 'tokenize'
            response['error']['message']
          else
            if response.key?('data') && response['data'].key?('message')
              message = response['data']['message'].to_s
            elsif response['appCode'] === 4
              message = response['appMessage']
            elsif response.key?('meta') && response['meta'].key?('errors') && response['meta']['errors'].kind_of?(Array)
              message = response['meta']['errors'].compact.join(', ')
            end
          end
        end

        message
      end

      def authorization_from(action, response)
        if action == 'tokenize'
          response['id']
        else
          response['data']['paymentUuid']
        end
      end

      def post_data(action, params = {})
        if action == 'tokenize'
          return nil unless params

          params.map do |key, value|
            next if value != false && value.blank?
            if value.is_a?(Hash)
              h = {}
              value.each do |k, v|
                h["#{key}[#{k}]"] = v unless v.blank?
              end
              post_data(action, h)
            elsif value.is_a?(Array)
              value.map { |v| "#{key}[]=#{CGI.escape(v.to_s)}" }.join("&")
            else
              "#{key}=#{CGI.escape(value.to_s)}"
            end
          end.compact.join("&")
        else
          params.to_json
        end
      end

      def error_code_from(action ,response)
        unless success_from(action, response)
          if action == 'tokenize'
            code = response['error']['code']
            decline_code = response['error']['decline_code'] if code == 'card_declined'

            error_code = STANDARD_ERROR_CODE_MAPPING[decline_code]
            error_code ||= STANDARD_ERROR_CODE_MAPPING[code]
            error_code
          else
            app_code = response['appCode']

            if response['data'].key?('code')
              error_code = STANDARD_ERROR_CODE_MAPPING[response['data']['code']] || 'unknown'
            else
              error_code = app_code.to_s
            end

            error_code
          end
        end
      end

    end
  end
end
