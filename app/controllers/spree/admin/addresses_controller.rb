module Spree
  module Admin
    class AddressesController < ResourceController
      helper Spree::AddressesHelper
      include Spree::AddressUpdateHelper

      before_filter :set_user_or_order
      before_filter :get_address_list
      before_filter :find_address, only: [:edit, :update, :destroy]

      def new
        unless @order.try(:can_update_addresses?) || @user.try(:can_update_addresses?)
          flash[:error] = Spree.t(:addresses_not_editable, resource: (@user || @order).try(:class).try(:model_name).try(:human))
          redirect_to collection_url
          return
        end

        country_id = Spree::Address.default.country.id
        @address = Spree::Address.new(:country_id => country_id, user: @user)
      end

      def create
        country_id = Spree::Address.default.country.id
        @address = Spree::Address.new({ country_id: country_id, user: @user }.merge!(address_params))

        # Don't allow creating duplicate addresses on a user or guest order
        match = @addresses.find(@address)
        if match
          match.destroy_duplicates
          match.update_all_attributes(address_params)
          @address = match.primary_address
        end

        if @address.save
          assign_order_address if @order
        end

        errors = []
        errors.concat @address.errors.full_messages

        if @order
          errors.concat @order.errors.full_messages
          errors.concat @order.bill_address.errors.full_messages if @order.bill_address
          errors.concat @order.ship_address.errors.full_messages if @order.ship_address
        end

        if errors.any?
          flash[:error] = errors.uniq.to_sentence
          render :new
        else
          flash[:success] = Spree.t(:account_updated)
          redirect_to collection_url
        end
      end

      def edit
        if !@address.editable?
          flash[:error] = I18n.t(:address_not_editable, scope: [:address_book])
          redirect_to collection_url
          return
        end
      end

      def update
        uaddrcount(@user, "AAC:u:b4(aid=#{@address.try(:id).inspect})", order: @order) # XXX

        @address, new_match, old_match = update_and_merge(@address, @addresses)

        uaddrcount(@user, "AAC:u:mid(aid=#{@address.try(:id).inspect})", order: @order) # XXX


        if new_match && old_match
          addrmatrix(new_match.addresses, old_match.addresses) # XXX
        end


        # XXX
        puts "    \e[35mAddress count: #{@addresses.try(:count).inspect}  New IDs: #{new_match.try(:addresses).try(:map, &:id).inspect}  Old IDs: #{old_match.try(:addresses).try(:map, &:id).inspect}\e[0m"
        #ap @new_match.try(:addresses)
        #ap @old_match.try(:addresses)
        #ap @addresses.try(:addresses).try(:map, &:addresses)
        ap @address
        ap params
        # XXX

        # FIXME: This seems wrong and incomplete TODO: tests don't trigger reassignment
        # TODO: Is some of this block rendered irrelevant by order and user decorators?
        if @order && (@order.bill_address.try(:editable?) || @order.ship_address.try(:editable?))
          # The order's before_validation #delink_addresses hook will take care
          # of assigning/cloning addresses, so just set the address IDs.

          if Spree::Address.find_by_id(@order.bill_address_id).nil? || @order.bill_address.try(:deleted_at)
            if old_match.try(:order_bill) || new_match.try(:order_bill)
              puts "\n\n\n   \e[1mReassigning order bill\e[0m\n\n\n" # XXX
              @order.bill_address.destroy unless @order.bill_address.user_id
              @order.bill_address_id = @address.id
            end
          end

          if Spree::Address.find_by_id(@order.ship_address_id).nil? || @order.ship_address.try(:deleted_at)
            if old_match.try(:order_ship) || new_match.try(:order_ship)
              puts "\n\n\n   \e[1mReassigning order ship\e[0m\n\n\n" # XXX
              @order.ship_address.destroy unless @order.ship_address.user_id
              @order.ship_address_id = @address.id
            end
          end

          if @order.errors.any?
            @address.errors.add(:order, @order.errors.full_messages.to_sentence)
          end
        end

        assign_order_address if @order && @address.errors.empty?

        if @address.errors.any?
          flash[:error] = @address.errors.full_messages.uniq.to_sentence
          render :edit
        else
          flash[:success] = Spree.t(:account_updated)
          redirect_to collection_url
        end

        uaddrcount(@user, "AAC:u:aft(#{flash.to_hash})", order: @order) # XXX
      end

      def destroy
        a = @addresses.find(@address) || @address

        # Only destroys user and guest order addresses, not delinked order
        # addresses (FIXME?  Should it be possible to destroy an order
        # address?)
        if a.destroy
          flash[:success] = Spree.t(:account_updated)
        else
          flash[:error] = @address.errors.full_messages.to_sentence
        end

        redirect_to collection_url
      end

      def update_addresses
        uaddrcount(@user, "AAC:ua:b4", order: @order) # XXX

        errors = []

        if @user
          update_object_addresses(@user, params[:user])
          errors.concat @user.errors.full_messages
        end

        if @order
          update_object_addresses(@order, params[:order])
          errors.concat @order.errors.full_messages
        end

        if errors.any?
          flash[:error] = (@user.try(:errors).try(:full_messages) + @order.errors.full_messages).to_sentence
        else
          flash[:success] = I18n.t(:default_addresses_updated, scope: :address_book)
        end

        redirect_to collection_url

        uaddrcount(@user, "AAC:ua:aft(#{flash.to_hash})", order: @order) # XXX
      end

      protected
        # Override Spree::Admin::ResourceController#collection_url to include user_id and order_id.
        def collection_url(options={})
          # TODO: Use more "resourceful" routing under Order and/or User
          super({order_id: @order.try(:id), user_id: @user.try(:id)}.merge!(options))
        end

      private
        def find_address
          if @order && !@user
            # Guest order; limit to the order's addresses
            if @order.bill_address.try(:id) == params[:id].to_i
              @address = @order.bill_address
            elsif @order.ship_address.try(:id) == params[:id].to_i
              @address = @order.ship_address
            else
              # Trigger a 404
              raise ActiveRecord::RecordNotFound, "Could not find address #{params[:id].to_i} on order #{@order.number}"
            end
          else
            @address ||= Spree::Address.find(params[:id]) if params[:id]
          end

          if @user && @address.try(:user) && @user != @address.user
            raise "Address user does not match user being edited!"
          end

          authorize! action, @address if @address
        end

        # Load a deduplicated list of order and user addresses.
        def get_address_list
          if @order and @user
            # Non-guest order
            @addresses = Spree::AddressBookList.new(@user, @order)
          elsif @order
            # Guest order
            @addresses = Spree::AddressBookList.new(@order)
          elsif @user
            # User account
            @addresses = Spree::AddressBookList.new(@user)
          else
            # Nothing; set a blank list
            @addresses = Spree::AddressBookList.new(nil)
          end
        end

        def set_user_or_order
          @user ||= Spree::User.find(params[:user_id]) if params[:user_id]
          @order ||= Spree::Order.find(params[:order_id]) if params[:order_id]
          @user ||= @order.user if @order

          if @order && @user && @user != @order.user
            raise "User ID does not match order's user ID!"
          end

          authorize! action, @user if @user
          authorize! action, @order if @order

          if @order.nil? && @user.nil?
            flash[:error] = Spree.t(:no_resource_found, resource: 'order or user')
            redirect_to admin_path
          end
        end

        # Assigns a new or modified address to the order, if requested by the
        # user via the address type combobox.  Saves the order.  Use
        # @address.errors to detect any errors.
        def assign_order_address
          unless params[:address][:address_type]
            @order.save
          else
            unless @order.can_update_addresses?
              @order.save
              @address.errors.add(:order, Spree.t(:addresses_not_editable, resource: @order.class.model_name.human))
            else
              case params[:address][:address_type]
              when "bill_address"
                if @order.bill_address && !@order.bill_address.user && @order.bill_address.editable?
                  @order.bill_address.update_attributes(address_params)
                else
                  @order.bill_address = @address
                end

              when "ship_address"
                if @order.ship_address && !@order.ship_address.user && @order.ship_address.editable?
                  @order.ship_address.update_attributes(address_params)
                else
                  @order.ship_address = @address
                end
              end

              unless @order.save
                @address.errors.add(:order, @order.errors.full_messages.to_sentence)
              end
            end
          end
        end
    end
  end
end
