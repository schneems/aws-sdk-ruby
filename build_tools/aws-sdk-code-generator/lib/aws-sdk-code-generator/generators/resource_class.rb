require 'set'

module AwsSdkCodeGenerator
  module Generators
    class ResourceClass < Dsl::Class

      extend Helper

      # @option options [required, String] :name
      # @option options [required, Hash] :resource
      # @option options [required, Hash] :api
      # @option options [Hash] :paginators
      # @option options [Hash] :waiters
      # @option options [String] :var_name (underscore(name))
      def initialize(options)
        @api = options.fetch(:api)
        @name = options.fetch(:name)
        @resource = options.fetch(:resource)
        @paginators = options.fetch(:paginators, nil)
        @waiters = options.fetch(:waiters, nil)
        @var_name = options.fetch(:var_name, underscore(@name))
        super(@name)
        build
        check_for_method_name_conflicts!
      end

      private

      def build
        extend_module('Aws::Deprecations')
        add(initialize_method)
        code('# @!group Read-Only Attributes')
        add(*identifier_getters)
        add(*data_attribute_getters)
        code('# @!endgroup')
        add(client_getter)
        add(load_method)
        add(data_method)
        add(data_loaded_method)
        add(exists_method)
        add(*waiters)
        apply_actions
        apply_associations
        add(identifiers_method)
        add(*private_methods)
        add(Generators::Resource::CollectionClass.new(
          resource_name: @name,
          resource: @resource,
        ))
      end

      def initialize_method
        Generators::Resource::InitializeMethod.new(resource: @resource)
      end

      def identifier_getters
        identifiers.map do |i|
          Generators::Resource::IdentifierGetter.new(identifier: i)
        end
      end

      def data_attribute_getters
        data_attribute_names.map do |member_name, member_ref|
          Generators::Resource::DataAttributeGetter.new(
            api: @api,
            member_name: member_name,
            member_ref: member_ref
          )
        end
      end

      def client_getter
        Generators::Resource::ClientGetter.new
      end

      def load_method
        Generators::Resource::LoadMethod.new(
          resource_name: @name,
          definition: @resource['load']
        )
      end

      def data_method
        Generators::Resource::DataMethod.new(
          resource_name: @name,
          resource: @resource
        )
      end

      def data_loaded_method
        Generators::Resource::DataLoadedMethod.new
      end

      def exists_method
        if @resource['waiters'] && @resource['waiters']['Exists']
          Generators::Resource::ExistsMethod.new(
            resource_name: @name,
            resource: @resource,
            waiters: @waiters,
          )
        end
      end

      def waiters
        (@resource['waiters'] || {}).map do |waiter_name, waiter|
          Generators::Resource::WaiterMethod.new(
            resource_name: @name,
            resource: @resource,
            resource_waiter_name: waiter_name,
            resource_waiter: waiter,
            waiter: @waiters['waiters'][waiter['waiterName']]
          )
        end
      end

      def apply_actions
        actions = @resource['actions'] || {}
        return if actions.empty?
        code('# @!group Actions')
        actions.each do |name, action|
          add(Resource::Action.new(
            api: @api,
            name: name,
            action: action,
            var_name: @var_name,
          ))
        end
      end

      def apply_associations
        associations = []
        associations += has_associations
        associations += has_many_associations

        return if associations.empty?

        code('# @!group Associations')
        associations.sort_by(&:name).each do |association_method|
          add(association_method)
        end
      end

      def has_associations
        (@resource['has'] || {}).map do |name, has|
          Resource::HasAssociation.new(
            api: @api,
            name: name,
            has: has
          )
        end
      end

      def has_many_associations
        (@resource['hasMany'] || {}).map do |name, has_many|
          Resource::HasManyAssociation.new(
            name: name,
            has_many: has_many,
            api: @api,
            paginators: @paginators,
            var_name: @var_name,
          )
        end
      end

      def identifiers_method
        Generators::Resource::IdentifiersMethod.new(
          identifiers: identifiers
        )
      end

      def private_methods
        methods = []
        methods.concat(extract_identifier_methods)
        methods << yield_waiter_and_warn_method
        methods.compact
      end

      def extract_identifier_methods
        identifiers.map.with_index do |identifier, n|
          Generators::Resource::ExtractIdentifierMethod.new(
            identifier: identifier,
            index: n
          )
        end
      end

      def identifiers
        @resource['identifiers'] || []
      end

      def data_attribute_names

        skip = Set.new

        # do no duplicate identifiers
        identifiers.each do |i|
          skip << i['name']
          skip << i['memberName'] if i.key?('memberName')
        end

        # do no duplicate action names
        (@resource['actions'] || {}).keys.each do |action_name|
          skip << action_name
        end

        # do no duplicate has association names
        (@resource['has'] || {}).keys.each do |association_name|
          skip << association_name
        end

        # do no duplicate hasMany association names
        (@resource['hasMany'] || {}).keys.each do |association_name|
          skip << association_name
        end

        shape = (@api['shapes'] || {})[@resource['shape']] || {}
        members = shape['members'] || {}
        Enumerator.new do |y|
          members.each do |member_name, member_ref|
            unless skip.include?(member_name)
              y.yield(member_name, member_ref)
            end
          end
        end
      end

      def check_for_method_name_conflicts!

        names = Set.new

        # Ensure the resource does not have duplicate names. This
        # includes comparing identifier names, action names, association
        # names, e.g. anything that is exposed as a method.
        @code_objects.each do |code_obj|
          if Dsl::Method === code_obj || Dsl::AttributeAccessor === code_obj
            check_for_duplicate_method!(code_obj.name, names)
          end
        end

        # It is possible for Dsl::Method#aliases to collide with
        # code object names. Remove aliases that collide.
        @code_objects.each do |code_obj|
          if Dsl::Method === code_obj
            code_obj.aliases.each do |alias_name|
              if names.include?(alias_name.to_s)
                code_obj.aliases.delete(alias_name.to_s)
              end
            end
          end
        end

        # Compare all resource methods against methods defined
        # on Ruby's Object class as an instance method. We need to
        # ensure we do not clobber built in Ruby functionality.
        Object.instance_methods.each do |obj_method_name|
          if names.include?(obj_method_name.to_s)
            raise Errors::ResourceMethodConflict.new(
              resource_name: @name,
              method_name: obj_method_name
            )
          end
        end
      end

      def check_for_duplicate_method!(method_name, names)
        method_name = method_name.to_s
        if names.include?(method_name)
          raise Errors::ResourceMethodConflict.new(
            resource_name: @name,
            method_name: method_name
          )
        else
          names << method_name
        end
      end

      def yield_waiter_and_warn_method
        if @resource['waiters'] && @resource['waiters'].size > 0
          Dsl::Method.new(:yield_waiter_and_warn, access: :private) do |m|
            m.param(:waiter)
            m.block_param
            m.code(<<-CODE)
if !@waiter_block_warned
  msg = "pass options to configure the waiter; "
  msg << "yielding the waiter is deprecated"
  warn(msg)
  @waiter_block_warned = true
end
yield(waiter.waiter)
            CODE
          end
        end
      end

    end
  end
end