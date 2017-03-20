module ActiveMerchant
  module Billing
    #
    # Simple Adapter for Square response objects
    #
    # inherits from <tt>ActiveMerchant::Billing::Response</tt> so it works well with Spree code.
    # object
    #
    class SquareResponse < Response
      attr_reader :object

      def initialize(success, message, params = {}, options = {})
        super success, message, params, options
        @object = options[:object]
      end

      def authorization
        object.transaction.id rescue nil
      end
    end

    class SquareUp < Gateway
      attr_reader :card_api,
                  :transaction_api,
                  :customer_api,
                  :location_id,
                  :preferences

      def initialize(options = {})
        @preferences      = options
        @card_api         = SquareConnect::CustomerCardApi.new
        @transaction_api  = SquareConnect::TransactionApi.new
        @customer_api     = SquareConnect::CustomerApi
      end

      #
      # Performs a pre-authorization
      #
      def authorize(money, card, options = {})
        transaction { charge(cent_amount: money, card: card, delay_charge: true, **options.slice(:email, :currency)) }
      end

      #
      # Captures a pre-authorization
      #
      # We do not support partial pre-authorizations.
      #
      def capture(_, authorization, options = {})
        transaction { transaction_api.capture_transaction(preferences[:access_token], location_id, authorization) }
      end

      def purchase(money, card, options = {})
        transaction { charge(cent_amount: money, card: card, delay_charge: false, **options.slice(:email, :currency)) }
      end

      def credit(money, credit_card_or_vault_id, options = {})
        raise NotImplementedError
      end

      def refund(money, transaction_id, options = {})
        raise NotImplementedError
      end

      def void(authorization, options = {})
        transaction { transaction_api.void_transaction(preferences[:access_token], location_id, authorization) }
      end

      def verify(card, options = {})
        transaction { charge(cent_amount: 100, card: card, delay_charge: true, **options.slice(:email, :currency)) }
      end

      def store(card, options = {})
        order = options[:order]

        #
        # [TODO] Associate address with a card at a more appropriate place
        # This association will be useful as we're trying to use just the card when creating a customer profile on square
        #
        # ===Goals
        #  * use the card object alone, when creating customer profile on Square.
        #  * populate +gateway_customer_profile_id+ on the card with customer id received from Square.
        #
        #
        if card.address_id.blank?
          card.update_attributes(address_id: order.bill_address_id)
        end

        data = {
          card_nonce:      card.encrypted_data,
          cardholder_name: card.name
        }

        if order.bill_address
          data[:billing_address] = map_address order.bill_address
        end

        transaction do
          customer = get_or_create_customer(order)
          card.update_attributes(gateway_customer_profile_id: customer.square_id)
          card_api.create_customer_card(preferences[:access_token], customer.square_id, data)
        end
      end

      def update(card_id, card, options = {})
        raise NotImplementedError
      end

      def unstore(card_id, options = {})
        raise NotImplementedError
      end
      alias_method :delete, :unstore

      def supports_network_tokenization?
        false
      end

      private
      def transaction
        begin
          object = yield
          SquareResponse.new(true, object.to_s, object.to_hash, object: object)
        #
        # Gateway Error, e.g.: refused payment or an invalid request
        #
        rescue SquareConnect::ApiError => e
          SquareResponse.new(false, e.message, JSON.parse(e.response_body))
        #
        # Something went really wrong here.
        # [TODO] Notify the whole team about the issue.
        #
        rescue => e
          SquareResponse.new(false, e.message, {errors: e.backtrace})
        end
      end

      def map_address(address)
        {
            address_line_1:                  address.address1,
            address_line_2:                  address.address2,
            locality:                        address.city,
            administrative_district_level_1: address.state.try(:name),
            postal_code:                     address.zipcode,

            # setting 2 letter ISO code as country.
            country:                         address.country.try(:iso)
        }
      end

      #
      #
      # Performs a pre-authorization or a purchase.
      #
      # Square does not have different endpoints pre-authorizations and purchases.
      # Both go to the +charge+ endpoint. When +delay_capture+ is set true we perform a pre-authorization,
      # otherwise we charge directly.
      #
      # ===Examples:
      #
      #  * Charge user test@example.com, with card +card+ with $1:
      #     <tt>charge(cent_amount: 100, currency: 'USD', delay_charge: false, card: card, email: test@example.com)</tt>
      #  * Pre-authorize user test@example.com, with card +card+ with $1:
      #     <tt>charge(cent_amount: 100, currency: 'USD', delay_charge: true, card: card, email: test@example.com)</tt>
      #
      #
      def charge(cent_amount:, currency:, card:, email:, delay_charge: false)
        transaction_api.charge(preferences[:access_token], location_id, {
            idempotency_key:     SecureRandom.uuid,
            buyer_email_address: email,
            amount_money:        { amount: cent_amount, currency: currency },
            customer_id:         card.gateway_customer_profile_id,
            customer_card_id:    card.gateway_payment_profile_id,
            billing_address:     map_address(card.address),
            delay_capture:       delay_charge
        })
      end

      #
      #
      # Looks up an instance of +SquareCustomer+, based on:
      #  * the +order+ - in case of guest checkout).
      #  * the +user+ - for a logged in user.
      #
      # Square stores complete profiles of customers and we need a +customer_id+ in order to store a card.
      #
      # [TODO] We should not care about the order in this method, just about the card.
      #
      #
      def get_or_create_customer(order)
        square_customer = if order.user_id.present?
                            SquareCustomer.where(owner: order.user).first_or_create
                          else
                            SquareCustomer.where(owner: order).first_or_create
                          end

        return square_customer if square_customer.square_id.present?

        bill_address = order.bill_address

        data = {
            given_name:    bill_address.firstname,
            family_name:   bill_address.lastname,
            email_address: order.email,
            address:       map_address(bill_address),
            phone_number:  bill_address.phone,
        }

        #
        # Create Customer in Square here.
        # [TODO] Consider error handling.
        #
        result = SquareConnect::CustomerApi.new.create_customer(preferences[:access_token], data)

        square_customer.update_attributes(square_id: result.customer.id)

        return square_customer
      end

      def location_id
        @location_id = begin
          location_api = SquareConnect::LocationApi.new
          location_api.list_locations(preferences[:access_token]).locations.first.id
        end
      end
    end
  end
end