module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class VacaypayGateway < Gateway
      self.money_format = :dollars
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
        requires!(options, :api_key, :payment_strategy_uuid)

        @api_key = options[:api_key]
        @payment_strategy_uuid = options[:payment_strategy_uuid]
        @account_uuid = options.key?(:account_uuid) ? options[:account_uuid] : nil
      end

      def headers
        {
            'X-Auth-Token' => @api_key.to_s,
            'Content-Type' => 'application/json'
        }
      end

      def clear_account_uuid
        @account_uuid = ''
      end

      def get_account_uuid
        @account_uuid
      end

      def fetch_account_details_if_empty
        if @account_uuid.nil? || @account_uuid.to_s.empty? || @account_uuid === 'nil'
          fetch_account_details
        end
      end

      def fetch_account_details
        begin
          url = "#{self.live_url}payment-strategy/#{@payment_strategy_uuid.to_s}"
          response = parse(ssl_get(url, headers))
          @account_uuid = response['data']['accountUuid']
        rescue ResponseError
          # Not authentication part just fetching extra details - wait till we get the 401 if credentials invalid
        end
      end

      def purchase(money, payment_method, options={})
        post = {}

        add_invoice(post, money, options)
        add_payment_method(post, payment_method, options)
        add_address(post, payment_method, options)
        add_customer_data(post, options)
        add_settings(post, options)

        commit('charge', post)
      end

      def authorize(money, payment, options={})
        post = {}

        add_invoice(post, money, options)
        add_payment_method(post, payment, options)
        add_address(post, payment, options)
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
            gsub(%r("cvv\\?":\\?"[0-9]*\\?"), '\1[FILTERED]')
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

      def add_payment_method(post, payment, options)
        if options.key?(:cardToken)
          post[:cardToken] = options[:cardToken]
        else
          card = {}
          card[:name] = payment.name
          card[:number] = payment.number
          card[:cvv] = payment.verification_value
          card[:expiryYear] = format(payment.year, :four_digits)
          card[:expiryMonth] = format(payment.month, :two_digits)

          post[:card] = card
        end
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
        fetch_account_details_if_empty

        url = self.live_url + determine_endpoint(action, parameters)

        begin
          raw_response = ssl_post(url, post_data(action, parameters), headers)
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = parse(raw_response)
        end

        succeeded = success_from(response)

        Response.new(
            succeeded,
            message_from(succeeded, response),
            response,
            authorization: authorization_from(response),
            test: test?,
            error_code: error_code_from(response)
        )
      end

      def determine_endpoint(action, parameters)
        # Set uuid to 0 as we get a route not found (404) when account_uuid empty - this will return the expected 401
        account_uuid = @account_uuid.to_s.empty? ? '0' : @account_uuid.to_s

        if action == 'charge' || action == 'authorize'
          endpoint = "vacay-pay/accounts/#{account_uuid}/payments"
        elsif action == 'capture'
          endpoint = "vacay-pay/accounts/#{@account_uuid.to_s}/payments/#{parameters[:payment_uuid]}/capture"
        elsif action == 'refund' || action == 'void'
          endpoint = "vacay-pay/accounts/#{@account_uuid.to_s}/payments/#{parameters[:payment_uuid]}/refund"
        else
          raise ActiveMerchantError.new('Cannot commit without a valid endpoint')
        end

        endpoint
      end

      def success_from(response)
        response['appCode'] == 0;
      end

      def message_from(succeeded, response)
        if succeeded
          message = 'Succeeded'
        else
          if response.key?('data') && response['data'].key?('message')
            message = response['data']['message'].to_s
          elsif response['appCode'] === 4
            message = response['appMessage']
          elsif response.key?('meta') && response['meta'].key?('errors') && response['meta']['errors'].kind_of?(Array)
            message = response['meta']['errors'].compact.join(', ')
          end
        end

        message
      end

      def authorization_from(response)
        response['data']['paymentUuid']
      end

      def post_data(action, parameters = {})
        parameters.to_json
      end

      def error_code_from(response)
        unless success_from(response)
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
