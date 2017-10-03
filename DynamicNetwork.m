%% EventDrivenNetwork 
% This class extend <PhysicalNetwork> to enable handling of network events.
%
% Subclass should impelement _onAddingSlice_ and _onRemovingSlice_ to handle the network
% dynamics: deciding whether to admit a slice or not, and how to allocate/release
% reosurces.
%% TODO
% (2) resource reallocation: when flows were uncovered by the serving slice (due to new
%     origining or handover),  performing slice dimensioning considering reconfiguration
%     cost.
% (3) decide when to perform resource reallocation, if not unexpected flows or handovers. 
%     Options including:
%     (a) event-based: after every N events, performs a reconfiguration;
%     (b) period-based: after every T time, performs a reconfiguration;
%     (c) profit threshold based: after the profit of fast reconfiguration is lower than a
%         threshold, performs a reconfiguration;
%     (d) profit threshold based with prediction: additionaly predict the threshold*.
classdef DynamicNetwork < PhysicalNetwork & EventSender & EventReceiver

    methods
        function this = DynamicNetwork(varargin)
            global InfoLevel;
            % Only called by subclasses, other member must be initialized by subclasses.
            %             this@PhysicalNetwork(varargin);
            if length(varargin)>=4
                this.options = structmerge(this.options, ...
                    getstructfields(varargin{4}, ...
                    {'VNFReconfigCoefficient', 'DiffNonzeroTolerance'}, 'ignore'));
            end
            if ~isfield(this.options, 'VNFReconfigCoefficient')
                % |VNFReconfigCoefficient|'s default value is 3.
                this.options.VNFReconfigCoefficient = 3;
                if InfoLevel.Class >= DisplayLevel.Notify
                    warning('''VNFReconfigCoefficient'' options is not specfied, set as %d.', ...
                        this.options.VNFReconfigCoefficient);
                end
            end
            if ~isfield(this.options, 'DiffNonzeroTolerance')
                this.options.DiffNonzeroTolerance = 10^-3;
                if InfoLevel.Class >= DisplayLevel.Notify
                    warning('''DiffNonzeroTolerance'' options is not specfied, set as %E.', ...
                        this.options.DiffNonzeroTolerance);
                end
            end
        end
    end
    
    methods        
        %%%
        % Since CloudNetwork and EventDrivenNetwork has different definition of AddSlice,
        % we need override the two superclass methods.
        function sl = AddSlice(this, slice_opt, varargin)
            AddSlice@PhysicalNetwork(this, slice_opt, varargin{:});
            %% Perform admiting control and resource allocation
            % Compute the resource allocation for the slice, and decide if this slice can
            % be admitted.
            % NOTE: currently we admit all slice request, so this function also does not
            % do anything.
            %
            % Subclasses should implement <onAddingSlice>.
            sl = this.onAddingSlice(this.slices{end});
            %% TODO: provide options when constructing the network.
        end        
        function sl = RemoveSlice(this, arg1)
            sl = RemoveSlice@PhysicalNetwork(this, arg1);
            sl = this.onRemovingSlice(sl);
        end
                
    end
    
    methods
        function eventhandler(this, source, eventData)
            global DEBUG; %#ok<NUSED>
            % target = eventData.targets;
            % where target should be the <DynamicNetwork> object.
            %% TODO: adding dynamic slice dimensioning for flow arrival/departure scale.
            ev = eventData.event;
            switch eventData.EventName
                case 'SliceArrive'
                    et = ev.Entity;
                    sl = this.AddSlice(et.Options);
                    % 2. Allocate flow id: should it be allocated by the Network or
                    % allocated by the Event Dispatcher.
                    % Inform the <EventDispatcher> to add existing flows and the flow
                    % entity builder.
                    if isempty(sl)
                        notify(this, 'AddSliceFailed');
                    else
                        sl.Identifier = et.SliceIdentifier;
                        if sl.isDynamicFlow
                            this.AddListener(sl, {'FlowArrive', 'FlowDepart'}, @sl.eventhandler);
                            sl.AddListener(this, {'AddFlowSucceed', 'AddFlowFailed', ...
                                'RemoveFlowSucceed', 'RemoveFlowFailed'}, @this.eventhandler);
                        end
                        data = DispatchEventData(ev, sl);
                        % The |entity| and |slice| information are needed to create flow
                        % entitities.
                        notify(this, 'AddSliceSucceed', data);
                    end
                    % Who should listen to slice and who should slice send events to?
                    % sl.AddListeners()
                case 'SliceDepart'
                    % Remove the slice if 'mandatorydepart' is enable; otherwise, if
                    % 'naturaldepart' is enabled, we set a flag. and until the last one
                    % flow of this slice departs, we remove the slice.
                    sl = ev.userdata;
                    if strcmpi(source.flow_depart_option, 'naturaldepart')
                        sl.b_ondepart = true;
                    else
                        this.RemoveSlice(sl);
                        data = FlowEventData(ev, sl, []);
                        notify(this, 'RemoveSliceSucceed', data);
                    end
                case 'FlowArrive'
                    %%%
                    % Notify slice that a flow arrives.
                    % |SliceIdentifier| of <SliceEntity> is equal to the |Identifier| of
                    % <Slice>.
                    % NOTE: handle may also be used in place of |Identifier|.
                    % TODO: pass the slice identifier directly through event data.
                    slice_id = ev.Entity.Parent.SliceIdentifier;
                    sl = this.slices{this.findSlice(slice_id, 'Identifier')};
                    ft = this.createflow(sl);
                    data = FlowEventData(ev, sl, ft);
                    %                     data.targets = this.FindSlice(et.Parent.SliceIdentifier);
                    notify(this, 'FlowArrive', data);
                case 'FlowDepart'
                    % notify slice
                    % TODO: remove flow entity child form slice entity
                    slice_id = ev.Entity.Parent.SliceIdentifier;
                    sl = this.slices{this.findSlice(slice_id, 'Identifier')};
                    flow_id = ev.Entity.GlobalIdentifier;
                    data = FlowEventData(ev, sl, flow_id);
                    notify(this, 'FlowDepart', data);
                    if strcmpi(source.flow_depart_option, 'naturaldepart')
                        if sl.b_ondepart && sl.NumberFlows == 0
                            % Finally remove the slice from the network
                            this.RemoveSlice(sl);
                            % then remove the slice entity form the entity list.
                            data = FlowEventData(ev, sl, []);
                            notify(this, 'RemoveSliceSucceed', data);
                        end
                    end
                case 'AddFlowSucceed'
                    % allocate flow id
                    % notify <EventDispatcher> to assign identifier to flow entry
                    fidx = eventData.flow;
                    sl = eventData.slice;
                    identifier = this.flow_identifier_generator.next(length(fidx));
                    sl.FlowTable{fidx, 'Identifier' } = identifier;
                    eventData = DispatchEventData(eventData.event, identifier);
                    notify(this, 'AddFlowSucceed', eventData);
                case 'AddFlowFailed'
                    % notify <EventDispatcher> to remove the invalid flow entry.
                case 'RemoveFlowSucceed'
                    data = EventData(eventData.entity);
                    notify(this, 'RemoveFlowSucceed', data);
                case 'RemoveFlowFailed'
                otherwise
                    error('error: cannot handle event %s.', eventData.EventName);
            end
        end
    end
        
    methods (Abstract, Access = protected)
        %% Perform admitting control and resource allocation
        % Compute the resource allocation for the slice, and decide if this slice can
        % be admitted.
        % NOTE: currently we admit all slice request, so this function also does not
        % do anything.
        %         function tf = OnAddlingSlice(this)
        %             tf = true;
        %         end
        tf = onAddingSlice(this, sl);
        tf = onRemovingSlice(this);
    end
    methods (Access =protected)
        function sl = createslice(this, slice_opt)
            % examine flow arrival parameters.
            % usage of <Slice>: if a slice without |ArrivalRate| or |ServiceInterval| or
            % their values are invalid, the slice (<Slice> or <DynamicSlice>) is treated
            % as no dynamics of flow, and it will not handle flow events. Therefore
            % initilize it as class <Slice> is OK.
            if ~isfield(slice_opt, 'ArrivalRate') || ~isfield(slice_opt, 'ServiceInterval')
                this.slices{end+1} = Slice(slice_opt);
            elseif isempty(slice_opt.ArrivalRate) || isempty(slice_opt.ServiceInterval)
                this.slices{end+1} = Slice(slice_opt);
                warning('slice created with type Slice.');
            else
                this.slices{end+1} = DynamicSlice(slice_opt);
            end
            sl = this.slices{end};
        end
        %%%
        % *Create new flows*
        % Creating new flows in the slice could guarantee no extra node or link would be
        % needed. If we enable new flows from new locations, we should create the flow
        % in the network.
        % |ft|: return flow table entries.
        function ft = createflow(this, slice, numflow)
            % map virtual network to physical network
            A = spalloc(this.NumberNodes, this.NumberNodes, this.NumberLinks);
            C = spalloc(this.NumberNodes, this.NumberNodes, this.NumberLinks);
            for i = 1:slice.NumberVirtualLinks
                h = slice.Topology.Head(i);
                t = slice.Topology.Tail(i);
                ph = slice.VirtualNodes{h, 'PhysicalNode'};
                pt = slice.VirtualNodes{t, 'PhysicalNode'};
                A(ph, pt) = slice.Topology.Adjacent(h,t); %#ok<SPRIX>
                C(ph, pt) = slice.Topology.Capacity(h,t); %#ok<SPRIX>
            end
            graph = DirectedGraph(A, C);
            slice_opt.FlowPattern = slice.Options.FlowPattern;
            slice_opt.DelayConstraint = slice.Options.DelayConstraint;
            slice_opt = this.updateDynamicSliceOptions(slice, slice_opt);
            if nargin <= 2
                slice_opt.NumberFlows = 1;
            else
                slice_opt.NumberFlows = numflow;
            end
            slice_opt.NumberPaths = slice.Options.NumberPaths;
            slice_opt.Method = 'dynamic-slicing';
            b_vailid_flow = false;
            while ~b_vailid_flow
                try
                    b_vailid_flow = true;
                    ft = this.generateFlowTable(graph, slice_opt);
                catch ME
                    disp(ME)
                    if strcmp(ME.identifier, 'PhysicalNetwork:Disconnected')
                        b_vailid_flow = false;
                    else
                        rethrow(ME);
                    end
                end
            end
            %%%
            % Update slice information as creating slice.
            %% TODO
            % When new nodes/edges should be added.
            ft.Properties.VariableNames = ...
                {'Source', 'Target', 'Rate', 'Delay', 'Paths'};
            for k = 1:height(ft)
                path_list = ft{k,{'Paths'}};
                for p = 1:path_list.Width
                    path = path_list.paths{p};
                    path.node_list = slice.PhyscialNodeMap{path.node_list,'VirtualNode'};
                    path.id = this.path_identifier_generator.next;
                end
            end
        end
        %%
        % |finalize| should be called by subclass's _funalize_ method.
        function finalize(this)
            for i = 1:this.NumberSlices
                sl = this.slices{i};
                sl.setVnfCapacity;
                %                 if strcmp(this.options.PricingPolicy, 'quadratic-price')
                %% Reconfiguration Cost
                % intra-slice reconfiguration: the flow reassignment cost and the VNF
                % instance reconfiguration cost is denpendtent on the resource
                % consummption in the slice; 
                % inter-slice reoncfiguration: the VNF node resource allocation cost is
                % dependent on the total load of the substrat network.
                [~, edge_reconfig_cost ] = sl.fcnLinkPricing(...
                    sl.VirtualLinks.Price, sl.VirtualLinks.Load);
                sl.VirtualLinks.ReconfigCost = DynamicSlice.THETA*edge_reconfig_cost;
                % here the |node_price| is the price of all data centers.
                [~, node_reconfig_cost] = sl.fcnNodePricing(...
                    sl.VirtualDataCenters.Price, sl.VirtualDataCenters.Load);
                sl.VirtualDataCenters.ReconfigCost = ...
                    DynamicSlice.THETA*node_reconfig_cost;
                vrc = this.options.VNFReconfigCoefficient;
                sl.vnf_reconfig_cost = vrc * repmat(node_reconfig_cost, sl.NumberVNFs, 1);
                %                 else
                %                 end
            end
        end
    end
    events
        FlowArrive;
        FlowDepart;
        AddSliceSucceed;
        AddSliceFailed;
        RemoveSliceSucceed;
        RemoveSliceFailed;          % NOT used.
        AddFlowSucceed;
        AddFlowFailed;
        RemoveFlowSucceed;
        RemoveFlowFailed;          % NOT used.
    end
        
    methods(Static, Access = protected)
        %%%
        % subclass can override this method, Called by _createflow_ method.
        function slice_opt = updateDynamicSliceOptions(slice, slice_opt)
            switch slice.Options.FlowPattern
                case {FlowPattern.RandomSingleFlow, FlowPattern.RandomMultiFlow}
                    slice_opt.NodeSet = slice.VirtualNodes.PhysicalNode;
                otherwise
                    error('error: cannot handle the flow pattern <%s>.', ...
                        slice.Options.FlowPattern.char);
            end
        end
    end
end

