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
            # Shopify-style: only multiply the items (nodes/edges) subtree by an effective, capped page size
            # and add a small, separate metadata cost (eg, pageInfo subfields), avoiding nested double-multiplication.
            lookahead = GraphQL::Execution::Lookahead.new(query: query, field: field_defn, ast_nodes: nodes, owner_type: @parent_type)

            has_page_info = false
            lookahead.selections.each do |sel|
              name = sel.name.to_s
              if name == "pageInfo"
                has_page_info = true
              end
            end

            # Shopify: pageInfo contributes ~2 to requested total, but shouldn't be multiplied.
            metadata_complexity = has_page_info ? 2 : 0

            # Remove the pageInfo object's base cost (1) from children before multiplying
            base_children = (child_complexity || 0)
            items_complexity = has_page_info ? (base_children - 1) : base_children
            items_complexity = 0 if items_complexity < 0

            effective_page_size = effective_connection_size(nodes, query, field_defn)
            (effective_page_size * items_complexity) + metadata_complexity
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

        # Effective connection size using a calibrated logarithmic scale
        def effective_connection_size(nodes, query, field_defn)
          raw = 1
          nodes.each do |node|
            args = query.arguments_for(node, field_defn)
            current = args[:first] || args[:last]
            if current
              raw = [raw, current].max
            end
          end
          # Calibrate so that first: 250 => ~11
          k = 10.0 / Math.log(250.0)
          1 + (k * Math.log(raw.to_f)).floor
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
