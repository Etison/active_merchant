module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class RecurlyGateway < Gateway
      include Empty

      API_VERSION = 'v2019-10-10'.freeze

      self.default_currency = 'USD'
      self.money_format = :cents
      self.supported_countries = ['US']
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :diners_club, :jcb]
      self.homepage_url = 'https://recurly.com/'
      self.display_name = 'Recurly'

      attr_accessor :post_params

      def initialize(options = {})
        requires!(options, :subdomain, :api_key, :public_key)
        super
      end

      def purchase(amount, payment_method, options={})
        post = {}
        add_amount(post, amount, options)
        add_payment_method(post, payment_method, options)
        add_purchase_line_items(post, options) unless subscription?(options)
        add_customer_data(post, options)
        type = subscription?(options) ? 'subscriptions' : 'purchases'
        @post_params = post
        commit(type, post)
      end

      def add_purchase_line_items(post, options={})
        post[:line_items] = options[:line_items] if options[:line_items].present?
      end

      private

      def add_amount(post, money, options)
        if subscription?(options)
          post[:plan_code] = options[:plan_code]
        end
        post[:currency] = options[:currency] || currency(money)
      end

      def add_customer_data(post, options)
        %i(code first_name last_name email).each do |option|
          post[:account][option] = options[option] if options[option].present?
        end
        if(billing_address = options[:billing_address] || options[:address])
          post[:account][:billing_info].merge!(billing_address)
          post[:account][:billing_info][:phone] = options[:phone] if options[:phone].present?
        end
        if(shipping_address = options[:shipping_address])
          post[:shipping_address] = billing_address
        end
      end

      def add_payment_method(post, payment_method, options)
        post[:account] = {}
        post[:account][:billing_info] = {}
        post[:description] = options[:description] if options[:description].present?
        if(payment_method.is_a?(String))
          post[:account][:billing_info][:token_id] ||= payment_method
        else
          post[:account][:billing_info][:number] = payment_method.number
          post[:account][:billing_info][:month] = payment_method.month
          post[:account][:billing_info][:year] = payment_method.year
          unless empty?(payment_method.verification_value)
            post[:account][:billing_info][:verification_value] = payment_method.verification_value
          end
        end
      end

      def authorization_from(response)
        return trial_payment_uuid if trial_payment?
        response['uuid'].presence || invoice['transactions'][0]['uuid']
      end

      def commit(endpoint, params = {})
        response = JSON.parse(ssl_post(url + endpoint, JSON.dump(params), headers))
        Response.new(
          success_from(response),
          message_from,
          response,
          authorization: authorization_from(response),
          test: test?
        )
      end

      def headers
        {
          'Authorization' => 'Basic ' + Base64.encode64(@options[:api_key]),
          'Content-Type'  => 'application/json; charset=utf-8',
          'Accept' => "application/vnd.recurly.#{API_VERSION}+json",
          'X-Api-Version' => API_VERSION
        }
      end

      def invoices
        response = ssl_get(url + 'invoices', headers)
        JSON.parse(response)['data']
      end

      def invoice
        @invoice ||= begin
          invoices.first(3).find do |inv|
            inv['account']['email'] ==  @post_params[:account][:email]
          end
        end
      end

      def message_from
        return trial_payment_status if trial_payment?
        invoice['transactions'][0]['status']
      end

      #
      # Checks if invoice paid by credit
      # status == collected and transactions are empty and amount the same
      #
      # @param [Hash] response
      def paid_credit_invoice?(response)
        return false unless invoice.present?
        invoice['transactions'].blank? &&
          invoice['state'] == 'collected' &&
          invoice['line_items'].first['type'] == 'credit' &&
          invoice['subtotal_in_cents'] == @post_params[:amount_in_cents].to_i
      end

      def subscription?(options)
        options[:plan_code].present?
      end

      def success_from(response)
        response['uuid'] = invoice['line_items'].first['uuid'] if paid_credit_invoice?(response)
        response['uuid'] ||= response['charge_invoice']['transactions'][0]['uuid'] if response['charge_invoice'].present?
        response['uuid'].present?
      end

      def url
        "https://v3.recurly.com/sites/subdomain-#{@options[:subdomain]}/"
      end

      def trial_payment?
        invoice['transactions'].empty? and invoice["paid"] == 0.0
      end

      def trial_payment_status
        return invoice["state"]
      end

      def trial_payment_uuid
        return invoice["line_items"]["data"].first["uuid"]
      end
    end
  end
end
