# frozen_string_literal: true

require "graphql/analysis"

module GraphQL
  module Analysis
    # A shopify complexity calculator that applies specific rules for different field types.
    class ShopifyComplexity < GraphQL::Analysis::QueryComplexity
      # This class overrides the default complexity calculation for a field.
      class ShopifyScopedTypeComplexity < ScopedTypeComplexity
        def own_complexity(child_complexity)
          field_defn = @field_definition
          return child_complexity || 0 unless field_defn

          query = @query
          nodes = @nodes

          if field_defn.owner == query.schema.mutation
            10 + (child_complexity || 0)
          elsif field_defn.connection?
            page_size = get_page_size(nodes, query, field_defn)
            page_size * (child_complexity || 0)
          else
            field_type = field_defn.type.unwrap
            case field_type.kind
            when GraphQL::TypeKinds::SCALAR, GraphQL::TypeKinds::ENUM
              0
            when GraphQL::TypeKinds::OBJECT
              1 + (child_complexity || 0)
            when GraphQL::TypeKinds::INTERFACE, GraphQL::TypeKinds::UNION
              # Shopify: cost is the maximum of possible selections; no base +1
              child_complexity || 0
            else
              child_complexity || 0
            end
          end
        end

        private

        # Get the page size from `first` or `last` arguments.
        # We have to check all AST nodes for this field and take the largest value.
        def get_page_size(nodes, query, field_defn)
          page_size = 1 # Default to 1 if no args are provided
          nodes.each do |node|
            args = query.arguments_for(node, field_defn)
            current_size = args[:first] || args[:last]
            if current_size
              page_size = [page_size, current_size].max
            end
          end
          page_size
        end
      end

      # Override on_enter_field from QueryComplexity to use our shopify scope class.
      # This is a bit of a reimplementation of the base method, but it's necessary
      # to inject our shopify complexity calculation logic.
      def on_enter_field(node, parent, visitor)
        # We don't want to visit fragment definitions,
        # we'll visit them when we hit the spreads instead
        return if visitor.visiting_fragment_definition?
        return if visitor.skipping?
        return if @skip_introspection_fields && visitor.field_definition.introspection?
        parent_type = visitor.parent_type_definition
        field_key = node.alias || node.name

        # Find or create a complexity scope stack for this query.
        scopes_stack = @complexities_on_type_by_query[visitor.query] ||= [ShopifyScopedTypeComplexity.new(nil, nil, query, visitor.response_path)]

        # Find or create the complexity costing node for this field.
        scope = scopes_stack.last[parent_type][field_key] ||= ShopifyScopedTypeComplexity.new(parent_type, visitor.field_definition, visitor.query, visitor.response_path)
        scope.nodes.push(node)
        scopes_stack.push(scope)
      end
    end
  end
end
