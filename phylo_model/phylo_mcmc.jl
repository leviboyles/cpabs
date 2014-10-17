require("phylo_model/phylo_model.jl")
require("tree.jl")
require("utils/probability_util.jl")
require("phylo_model/pdf.jl")
require("samplers/transformation.jl")

plot_utils_loaded = true
if Pkg.installed("Winston") != nothing
    require("utils/plot_utils.jl")
else
    println("Failed to load plot_utils.jl: disabling plotting")
    plot_utils_loaded = false
end

require("samplers/slicesampler.jl")
require("samplers/refractive_sampler.jl")
require("samplers/hmc.jl")

#@profile begin
function mcmc(data::DataState,
              lambda::Float64,
              gam::Float64,
              alpha::Float64,
              init_N::Int64,
              model_spec::ModelSpecification,
              iterations::Int64,
              burnin_iterations::Int64)

    # number of leaves is the number of split points plus one
    N = init_K+1

    (M,S) = size(data.reference_counts)
    eta = [rand(S) for i = 1:2N-1]
    tree = Tree(eta)

    InitializeBetaSplits(tree, () -> rand(Beta(1,1)))


    # initial root node must have nutd < 1.0
    root = FindRoot(tree,1)
    tree.nodes[root.index].rhot = 0.9


    Z = rand(1:N-1, M) + N
    # choose one mutation at random for each cluster to ensure they are nonempty
    perm = randperm(M)
    for k = 1:N-1
        Z[perm[k]] = k + N
    end


    model = ModelState(lambda,gam,alpha,tree,Z)


    trainLLs = Float64[]
    Ks = Int[]

    iters = Int[]

    models = Array(ModelState,0)
    debug = model_spec.debug 
    model_spec.debug = false

    local tbl

    t0 = time()

    chain_probs = Float64[]

    for iter = 1:iterations
        println("Iteration: ", iter)
        tree_prior = prior(model,model_spec)
        tree_LL = likelihood(model, model_spec, data)
        println("tree probability, prior, LL, testLL: ", tree_prior + tree_LL, ",", tree_prior, ",",tree_LL)

        if iter == 1 || tree_prior + tree_LL > chain_probs[end]+100
            Temp = 1.0
        end

        push!(chain_probs, tree_prior + tree_LL)
        if iter == 2 && debug
            model_spec.debug = true
        end

#        if iter < 0.5*iterations
#            Temp += 0.5
#        else
#            Temp = 1.0
#        end

        mcmc_sweep(model, model_spec, data, Temp=Temp)

        if model_spec.plot && plot_utils_loaded && mod(iter,10) == 0



            u = zeros(Int64, 2N-1)
            for i=1:length(Z)
                u[Z[i]] += 1
            end 

            ZZ, leaf_times, Etas, inds = model2array(model, return_leaf_times=true)
            p_dendrogram = dendrogram(ZZ,u[inds], plot=false, sorted_inds=inds, leaf_times=leaf_times)

            parent_prune_index = rand(N+1:2N-1)
            grandparent = tree.nodes[parent_prune_index].parent


            while grandparent == Nil()
                parent_prune_index = rand(N+1:2N-1)
                grandparent = tree.nodes[parent_prune_index].parent
            end


            #new_model = draw_neighboring_tree(model, model_spec, data, N)
            new_model = tree_kernel_sample(model, model_spec, data, parent_prune_index, eta_Temp=0.0000001)

            kernel_logpdf = tree_kernel_logpdf(new_model, model, model_spec, data, parent_prune_index, eta_Temp=.0000001, nutd_aug=nothing)



            ZZ, leaf_times, Etas, inds = model2array(new_model, return_leaf_times=true)
            new_u = zeros(Int64, 2(N+1)-1)
            for i=1:length(new_model.Z)
                x = new_model.Z[i]
                new_u[x] += 1
            end 
            p_dendrogram2 = dendrogram(ZZ,new_u[inds], plot=false, sorted_inds=inds, leaf_times=leaf_times)

            new_prior = prior(new_model, model_spec)
            new_LL = likelihood(new_model, model_spec, data)
            println("new Z: $(new_model.Z)")
            println("new_prior: $new_prior")
            println("new_LL: $new_LL")
            println("old_LL: $tree_LL")
            println("kernel_logpdf: $kernel_logpdf")
            if iter > burnin_iterations
                c = Curve([burnin_iterations:iter], chain_probs[burnin_iterations:iter], color="blue")
            else
                c = Curve([1:iter], chain_probs, color="blue")
            end
            p_chain = FramedPlot()
            add(p_chain,c)

            p_clusters = FramedPlot()
            cluster_names = ["" for i = 1:maximum(Z-N)]
            for i = 1:length(Z)
                cluster_names[Z[i]-N] = "$(cluster_names[Z[i]-N])$(cluster_names[Z[i]-N] == "" ? "" : "; ")$(data.mutation_names[i])"
            end
            add(p_clusters, Curve([0, 0], [0, 1], color="white"))
            #println("$cluster_names")
            phi = compute_phis(model)
            for i = 1:length(cluster_names)
#                pl = Winston.DataLabel(-0.9, 1.0-0.5*((i-1)/length(cluster_names)), "Cluster $(i+N): $(cluster_names[i])", halign="left" ) 
#                add(p_clusters, pl)
                eta = model.tree.nodes[i+N].state
                eta_string = @sprintf("%0.2f",eta[1])
                for k = 2:length(eta)
                    eta_string = "$eta_string, $(@sprintf("%0.2f",eta[k]))"
                end
                pl = Winston.DataLabel(-0.9, 1.0-0.5*((i-1)/length(cluster_names)), "Eta $(i+N): $eta_string", size=0.5, halign="left" ) 
                add(p_clusters, pl)

                phi_i = phi[i+N,:]
                phi_string = @sprintf("%0.2f",phi_i[1])
                for k = 2:length(phi_i)
                    phi_string = "$phi_string, $(@sprintf("%0.2f",phi_i[k]))"
                end
                pl = Winston.DataLabel(-0.9, 0.5-0.5*((i-1)/length(cluster_names)), "Phi $(i+N): $phi_string", halign="left" ) 
                add(p_clusters, pl)
            end

            tbl = Table(1,2)
            tbl2 = Table(3,1)
            tbl2[1,1] = p_dendrogram
            tbl2[2,1] = p_clusters
            tbl2[3,1] = p_dendrogram2
            tbl[1,1] = p_chain
            tbl[1,2] = tbl2
            Winston.display(tbl)
 
        end


        if mod(iter, 10) == 0 || iter == iterations
            push!(models,copy(model))
            push!(iters, iter)
        end
        push!(trainLLs, tree_LL)
        #push!(Ks, size(model.weights)[1])
    end

    tend = time() - t0
    println("total elapsed time: $tend")
    if model_spec.plot && plot_utils_loaded
        (iters, Ks, trainLLs, models, tbl )
    else
        (iters, Ks, trainLLs, models )
    end
end


function mcmc_sweep(model::ModelState,
                    model_spec::ModelSpecification,
                    data::DataState;
                    Temp::Float64 = 1.0)

    tree = model.tree

    tree_prior = prior(model,model_spec) 
    tree_LL = likelihood(model, model_spec, data)
    println("tree probability, prior, LL: ", tree_prior + tree_LL, ",", tree_prior, ",",tree_LL)

    psi_time = time()
    sample_psi(model, model_spec, data, Temp=Temp)
    psi_time = time() - psi_time

    tree_prior = prior(model,model_spec) 
    tree_LL = likelihood(model, model_spec, data)
    println("tree probability, prior, LL: ", tree_prior + tree_LL, ",", tree_prior, ",",tree_LL)

    slice_iterations = 5
    nu_time = time()
    sample_nu_nutd(model, model_spec, slice_iterations)
    nu_time = time() - nu_time
    tree_prior = prior(model,model_spec) 
    tree_LL = likelihood(model, model_spec, data)
    println("tree probability, prior, LL: ", tree_prior + tree_LL, ",", tree_prior, ",",tree_LL)

    hmc_iterations = 5
    eta_time = time()
    sample_eta(model, model_spec, data, hmc_iterations, Temp=Temp)
    eta_time = time() - eta_time

    tree_prior = prior(model,model_spec) 
    tree_LL = likelihood(model, model_spec, data)
    println("tree probability, prior, LL: ", tree_prior + tree_LL, ",", tree_prior, ",",tree_LL)

    Z_iterations = 1
    Z_time = time()
    sample_assignments(model, model_spec, data, Z_iterations, Temp=Temp)
    Z_time = time() - Z_time
    tree_prior = prior(model,model_spec) 
    tree_LL = likelihood(model, model_spec, data)
    println("tree probability, prior, LL: ", tree_prior + tree_LL, ",", tree_prior, ",",tree_LL)

    println("MCMC Timings (psi, nu, eta, Z) = ", (psi_time, nu_time, eta_time, Z_time))
end


# nu = nu_r = 1-nu_l = parent.rho
# nutd_l = l.rhot 
function sample_nu_nutd(model::ModelState,
                        model_spec::ModelSpecification,
                        slice_iterations::Int)

    println("Sample nu, nu-tilde")
    tree = model.tree
    gam = model.gamma
    lambda = model.lambda
    alpha = model.alpha
    Z = model.Z

    N::Int = (length(tree.nodes)+1)/2

    root = FindRoot(tree, 1)
    indices = GetLeafToRootOrdering(tree, root.index)

    u = zeros(2N-1)
    U_i = zeros(2N-1)

    Tau = Array(Node, 2N-1)
    P = Array(Array{Node}, 2N-1)
    #Self inclusive
    ancestors = Array(Array{Node}, 2N-1)
    K = zeros(2N-1, 2N-1)

    Pki = [Array(Node,0) for i = 1:2N-1] # {j | i in P[j]}
    An_i = [Array(Node,0) for i = 1:2N-1] # {j | i in ancestors[j]}
    An_tau = [Array(Node,0) for i = 1:2N-1] #{j | i in ancestor[tau(j)]}

    A_I = zeros(2N-1)
    A_tau = zeros(2N-1)

    An_ni = [Array(Node,0) for i = 1:2N-1] # {j | i not in ancestors[j]} 
    An_ntau = [Array(Node,0) for i = 1:2N-1] # {j | i not in ancestors[tau(j)]}

    root_An_ni = Array(Node,0)
    root_An_ntau = Array(Node,0)

    B_I = zeros(2N-1)
    B_tau = zeros(2N-1)

    C = [Int64[] for x=1:maximum(Z)]
    for i = 1:length(Z)
        push!(C[Z[i]], i)
    end

    for i = indices
        cur = tree.nodes[i]
        P[i] = tau_path(cur)
        Tau[i] = tau(cur)
        ancestors[i] = GetAncestors(tree,i)
        u[i] = length(C[i])-1
        @assert u[i] >= 0 || i <= N
    end
    u[1:N] = 0
    U = sum(u)

    for i = indices
        tau = Tau[i]

        An = tau == Nil() ? [] : ancestors[tau.index]
        for j in An
            U_i[j.index] += u[i]
        end 
    end

    
    for i = indices
        if i > N
            for k = P[i]
                push!(Pki[k.index], tree.nodes[i])
            end
            for k = ancestors[i]
                push!(An_i[k.index], tree.nodes[i])
            end
            tau = Tau[i]
            An = tau == Nil() ? [] : ancestors[tau.index]
            for k = An
                push!(An_tau[k.index], tree.nodes[i])
            end

            for k = indices
                cur = tree.nodes[k]
                if k > N
                    left_child = cur.children[2]
                    right_child = cur.children[1]
                    l = left_child.index
                    r = right_child.index
                   
     
                    if !(left_child in ancestors[i]) && !(right_child in ancestors[i])
                        push!(An_ni[k], tree.nodes[i])
                    end
                    tau = Tau[i]
                    An = tau == Nil() ? [] : ancestors[tau.index]
                    if !(left_child in An) && !(right_child in An)
                        push!(An_ntau[k], tree.nodes[i])
                    end
                end 
            end
           
            # (root_An_ni is always empty)

            if Tau[i] == Nil()
                push!(root_An_ntau, tree.nodes[i])
            end
        end
    end

    for i = reverse(indices)
        if i > N
            cur = tree.nodes[i]
            left_child = tree.nodes[i].children[2]
            right_child = tree.nodes[i].children[1]
            l = left_child.index
            r = right_child.index

            eta = cur.state

            N_l = left_child.num_leaves
            N_r = right_child.num_leaves
            N_p = cur.num_leaves
            
            nu_p = 1.0
            if i != root.index
                parent = cur.parent
                self_direction = find(parent.children .== cur)[1]
                nu_p = self_direction == 1 ? parent.rho : 1-parent.rho 
            end

            rhot = cur.rhot
            nutd_l = left_child.rhot
            nutd_r = right_child.rhot
 
            nu_r = cur.rho
            nu_l = 1-cur.rho

            update_nu_nutd_constants!(i,[l,r], gam, ancestors, Tau, Pki, P, An_i, An_tau, An_ni[i], An_ntau[i], K, A_I, A_tau, B_I, B_tau)

            K_l = zeros(2N-1)
            K_r = zeros(2N-1)


            times = compute_times(model)



            C_l = A_tau[l] - A_I[l]
            C_r = A_tau[r] - A_I[r]
            D = B_tau[i] - B_I[i]

#            ZZ, leaf_times, Etas, inds = model2array(model, return_leaf_times=true)
#            dend = dendrogram(ZZ,u[inds], leaf_times=leaf_times, sorted_inds=inds, plot=false)
#
#            v = zeros(N-1)
#            for j = 1:2N-1
#                jcur = tree.nodes[j]
#                parent = jcur.parent
#                if j > N
#                    tau_node = tau(jcur)
#                    tau_t = tau_node == Nil() ? 1.0 : times[tau_node.index]
#                    v[j-N] = tau_t - times[j]
#                end
#
#            end
#
#            V_fast = (nu_r*nutd_r)^gam * C_r + ((1-nu_r)*nutd_l)^gam * C_l + D 
#            V_slow = sum(v)
#
#            println("V_fast: $V_fast")
#            println("V_slow: $V_slow")
#            println("v: $v")
            p_s = 1 - 2/(N_l+N_r+1)
            p_sl = 1 - 2/(N_l+1)
            p_sr = 1 - 2/(N_r+1)

            

            if l > N

                # Sample nutd_l
                f = x -> logsumexp( nu_tilde_splits(nu_r, x, nutd_r, gam, U, U_i[l], U_i[r], u, 
                                        K[l,:], K[r,:], C_l, C_r, D, Pki[l], Pki[r], p_sl, node="l"))



                nutd_l = nutd_l == 1.0 ? rand(Uniform(0,1)) : nutd_l
                (nutd_u, f_nutd) = slice_sampler(nutd_l, f, 0.1, 10, 0.0, 1.0)

                f_vals = nu_tilde_splits(nu_r, nutd_u, nutd_r, gam, U, U_i[l], U_i[r], u, 
                                        K[l,:], K[r,:], C_l, C_r, D, Pki[l], Pki[r], p_sl, node="l")

                f_ind = rand(Categorical(exp_normalize(f_vals)))
                nutd_l = f_ind == 1 ? 1.0 : nutd_u
            end

            if r > N
                # Sample nutd_r
                f = x -> logsumexp( nu_tilde_splits(nu_r, nutd_l, x, gam, U, U_i[l], U_i[r], u, 
                                        K[l,:], K[r,:], C_l, C_r, D, Pki[l], Pki[r], p_sr, node="r"))

                nutd_r = nutd_r == 1.0 ? rand(Uniform(0,1)) : nutd_r
                (nutd_u, f_nutd) = slice_sampler(nutd_r, f, 0.1, 10, 0.0, 1.0)

                f_vals = nu_tilde_splits(nu_r, nutd_l, nutd_u, gam, U, U_i[l], U_i[r], u, 
                                        K[l,:], K[r,:], C_l, C_r, D, Pki[l], Pki[r], p_sr, node="r")

                f_ind = rand(Categorical(exp_normalize(f_vals)))
                nutd_r = f_ind == 1 ? 1.0 : nutd_u
            end

            # Sample nu_r = 1-nu_l

            f = x -> nu_logpdf(x, nutd_l, nutd_r, gam, U, U_i[l], U_i[r], u,
                                K[l,:], K[r,:], C_l, C_r, D, Pki[l], Pki[r], cur.state, alpha, N_l, N_r)

#            f1 = x -> p_z_given_nu_nutd(x, nutd_l, nutd_r, gam, U, U_i[l], U_i[r], u, 
#                                        K[l,:], K[r,:], C_l, C_r, D, Pki[l], Pki[r]) + p_nu_Nl_Nr(x, N_l, N_r)
#
#
#            left_child.rhot = nutd_l
#            right_child.rhot = nutd_r
#            f2 = x -> (tree.nodes[i].rho = x; full_pdf(model, model_spec, data))
#
#                    x_range = [0.01:0.01:0.99]
#                    f1_vals = [f(x) for x in x_range]
#                    f2_vals = [f2(x) for x in x_range]
#
#                    f1_vals -= maximum(f1_vals)
#                    f2_vals -= maximum(f2_vals)
#
#                    c1 = Curve(x_range, f1_vals, color="blue")
#                    c2 = Curve(x_range, f2_vals, color="red")
#
#                    p = FramedPlot()
#                    add(p, c2) 
#                    add(p, c1) 
#                    tbl = Table(1,2)
#                    tbl[1,1] = p
#                    tbl[1,2] = dend
#                    display(tbl)
#                    @assert false
 
            (nu_r, f_nu) = slice_sampler(nu_r, f, 0.1, 10, 0.0, 1.0)

            cur.rho = nu_r

            if i == root.index
                update_nu_nutd_constants!(i,[i], gam, ancestors, Tau, Pki, P, An_i, An_tau, root_An_ni, root_An_ntau, K, A_I, A_tau, B_I, B_tau)

                C_i = A_tau[i] - A_I[i]
                D = B_tau[i] - B_I[i]

                nutd_p = cur.rhot 
                nutd_p = nutd_p == 1.0 ? rand(Uniform(0,1)) : nutd_p

                f = x -> logsumexp( root_nu_tilde_splits(x, gam, U, U_i[i], u, 
                                        K[i,:], C_i, D, Pki[i], p_s))
                ##########
#                    println("i: $i")
#                    f1 = x -> root_nu_tilde_splits(x, gam, U, U_i[i], u, 
#                                            K[i,:], C_i, D, Pki[i], p_s)[2]
#                    f2 = x -> (tree.nodes[i].rhot = x; prior(model, model_spec, debug=false))
#
#                    x_range = [0.01:0.01:0.99]
#                    f1_vals = [f1(x) for x in x_range]
#                    f2_vals = [f2(x) for x in x_range]
#
#                    f1_vals -= maximum(f1_vals)
#                    f2_vals -= maximum(f2_vals)
#
#                    c1 = Curve(x_range, f1_vals, color="blue")
#                    c2 = Curve(x_range, f2_vals, color="red")
#
#                    p = FramedPlot()
#                    add(p, c2) 
#                    add(p, c1) 
#                    tbl = Table(1,2)
#                    tbl[1,1] = p
#                    tbl[1,2] = dend
#                    display(tbl)
#                    @assert false
                ##########
            
                (nutd_u, f_nutd) = slice_sampler(nutd_p, f, 0.1, 10, 0.0, 1.0)
                f_vals = root_nu_tilde_splits(nutd_u, gam, U, U_i[i], u,
                                        K[i,:], C_i, D, Pki[i], p_s)
                f_ind = rand(Categorical(exp_normalize(f_vals)))
                nutd_p = f_ind == 1 ? 1.0 : nutd_u
                @assert nutd_p != 1.0
                cur.rhot = nutd_p
            end


        end
    end

end

function update_nu_nutd_constants!(i, update_set, gam, ancestors, Tau, Pki, P, An_i, An_tau, An_ni, An_ntau, K, A_I, A_tau, B_I, B_tau)

    for a in update_set
        # Compute K(a,n) for n \in {n | a \in P(n)} 
        for n = Pki[a]
            j = n.index
            K[a,j] = 1.0
            for k = P[j]
                if k.index == a
                    continue
                end
                if k.parent == Nil()
                    K[a,j] *= (k.rhot)^gam
                else
                    k_direction = find(k.parent.children .== k)[1]
                    nu_k = k_direction == 1 ? k.parent.rho : 1-k.parent.rho
                    K[a,j] *= (k.rhot*nu_k)^gam
                end

            end
        end

        # Compute A(a,I)
        A_I[a] = 0.0
        for n = An_i[a]
            j = n.index
            prod = 1.0
            for k = ancestors[j]
                if k.index == a
                    continue
                end
                if k.parent == Nil()
                    prod *= k.rhot^gam
                else
                    k_direction = find(k.parent.children .== k)[1]
                    nu_k = k_direction == 1 ? k.parent.rho : 1-k.parent.rho
                    prod *= (k.rhot*nu_k)^gam
                end
            end
            A_I[a] += prod
        end
        # Compute A(a,tau)
        A_tau[a] = 0.0
        for n = An_tau[a]
            j = n.index
            prod = 1.0
            An_k = Tau[j] == Nil() ? [] : ancestors[Tau[j].index]
            for k = An_k
                if k.index == a
                    continue
                end
                if k.parent == Nil()
                    prod *= k.rhot^gam
                else
                    k_direction = find(k.parent.children .== k)[1]
                    nu_k = k_direction == 1 ? k.parent.rho : 1-k.parent.rho
                    prod *= (k.rhot*nu_k)^gam
                end
            end
            A_tau[a] += prod
        end

    end

    
    B_I[i] = 0.0
    for n = An_ni
        j = n.index
        prod = 1.0

        for k = ancestors[j]
            @assert !(k in update_set)
            if k.parent == Nil()
                prod *= k.rhot^gam
            else
                k_direction = find(k.parent.children .== k)[1]
                nu_k = k_direction == 1 ? k.parent.rho : 1-k.parent.rho
                prod *= (k.rhot*nu_k)^gam
            end
        end
        B_I[i] += prod 
    end

    B_tau[i] = 0.0
    for n = An_ntau
        j = n.index
        prod = 1.0
        An_k = Tau[j] == Nil() ? [] : ancestors[Tau[j].index]
        for k = An_k
            @assert !(k in update_set)
            if k.parent == Nil()
                prod *= k.rhot^gam
            else
                k_direction = find(k.parent.children .== k)[1]
                nu_k = k_direction == 1 ? k.parent.rho : 1-k.parent.rho
                prod *= (k.rhot*nu_k)^gam
            end
        end
        B_tau[i] += prod 
    end
end

function sample_psi(model::ModelState,
                    model_spec::ModelSpecification,
                    data::DataState;
                    Temp::Float64 = 1.0)

    tree = model.tree
    N::Int = (length(tree.nodes)+1)/2


    println("psi: ")
    for parent_prune_index = N+1:2N-1
         
        parent = tree.nodes[parent_prune_index]
        prune_index = parent.children[1].index

        if model_spec.debug
            old_prior = prior(model, model_spec)
            old_LL = likelihood(model, model_spec, data)
        end

        if mod(parent_prune_index-N+1,ceil(N/10)) == 0
            percent = ceil((parent_prune_index-N+1)/ceil(N/10))*10
            println(" ",percent , "% ")
        end

        old_model = copy(model)
        old_tree = old_model.tree


        grandparent = tree.nodes[prune_index].parent.parent
        if grandparent == Nil()
            continue
        end

        if parent.children[1].index == prune_index
            original_sibling = parent.children[2]
        else
            original_sibling = parent.children[1]
        end


#        correct_priors, correct_likelihoods = prune_graft_logprobs(model, model_spec, data, prune_index)

        PruneIndexFromTree!(model.tree, prune_index)

        gp = grandparent.index

        subtree_indices = GetSubtreeIndicies(tree, prune_index)
        i = 1
        while in(i,subtree_indices)
            i += 1
        end
        root = FindRoot(tree, i)
        path = GetLeafToRootOrdering(tree, root.index)
      

        (priors, pstates) = psi_infsites_logpdf(model, data, prune_index, path)
        (likelihoods, lstates) = psi_observation_logpdf(model, model_spec, data, prune_index, path)

#        priors = priors .- maximum(priors)
#
#        correct_priors = correct_priors .- maximum(correct_priors)
#        correct_likelihoods = correct_likelihoods .- maximum(correct_likelihoods)

#        println("prune_index: $prune_index") 
#        println("parent_prune_index: $parent_prune_index") 
#        println("states: $lstates") 
#        println("priors (efficient): $priors")
#        println("priors (correct): $correct_priors")
#        println("likelihoods (efficient): $likelihoods")
#        println("likelihoods (correct): $correct_likelihoods")

        logprobs = priors + likelihoods
        probs = exp_normalize(logprobs/Temp)

        if any(isnan(probs))
            nan_ind = find(isnan(probs))[1]
            maxprior = maximum(priors)
            maxll = maximum(likelihoods)
            println("ind,logprob,prob: ", (nan_ind, logprobs[nan_ind], probs[nan_ind]))
            println("maxprior, maxlikelihood = ", (maxprior, maxll))
            println(priors)
            println(likelihoods)
            println(lstates)
            assert(false)
        end

        state_index = randmult(probs)

        subtree_indices = GetSubtreeIndicies(tree, prune_index)
        i = 1
        while in(i, subtree_indices)
            i += 1
        end
        root = FindRoot(tree, i)



        @assert pstates[state_index] == lstates[state_index]

        graft_index = pstates[state_index]

        InsertIndexIntoTree!(model.tree, prune_index, graft_index) 

        println("graft_index: $graft_index")
        println("original_sibling_index: $(original_sibling.index)")

        if model_spec.debug 
            println("Sampling Prune Index: ", prune_index, " Num Leaves: ", length(GetLeaves(tree, grandparent.index)))
            println("Num Leaves pruned: ", length(GetLeaves(tree, prune_index)), " Num leaves remaining: ", length(GetLeaves(tree, gp)) )
            println("original_index,insert_index,parent,root: ", original_sibling.index, ",", pstates[state_index][1], ",", parent.index, ",", root.index)
#            println("logprobs: ", logprobs)
#            println("graft indices: ", graft_indices)

            println("graftpoint_features: $graftpoint_features")
            println("parent_features: $parent_features")

            subtree_indices = GetLeafToRootOrdering(tree, prune_index)
            grafttree_indices = GetLeafToRootOrdering(tree, graft_index)
            ancestor_indices = GetPath(tree, tree.nodes[prune_index].parent.index)

            count_features = x -> sum([tree.nodes[i].state for i in x])
            get_features = x -> [tree.nodes[i].state for i in x]

            subtree_num = count_features(subtree_indices)
            grafttree_num = count_features(grafttree_indices)
            ancestor_num = count_features(ancestor_indices)
           
            println("subtree num_features: $subtree_num") 
            println("grafttree num_features: $grafttree_num") 
            println("ancestor num_features: $ancestor_num") 
            println("original sibling under graftpoint?: $(original_sibling.index in grafttree_indices)")

            println("ancestors: $ancestor_indices")
            println("ancestor_features: $(get_features(ancestor_indices))")

            println("local_LL: $(likelihoods[state_index])")
            println("local_prior: $(priors[state_index])")
            println("old_local_LL: $(likelihoods[A])")
            println("old_local_prior: $(priors[A])")

            println("prob: $(probs[state_index])")
            println("old_prob: $(probs[A])")


            tree_prior = prior(model, model_spec) 
            tree_LL = likelihood(model, model_spec, data)
            println("tree probability, prior, LL, testLL: ", tree_prior + tree_LL, ",", tree_prior, ",",tree_LL, ",", test_LL)

            full_diff = tree_LL + tree_prior - old_LL - old_prior
            local_diff = likelihoods[state_index] + priors[state_index] -
                         likelihoods[A[1]] - priors[A[1]]

            all_local_diff =  likelihoods[state_index] + priors[state_index] .- likelihoods[A] .- priors[A]

            min_local_diff, ai = findmin(abs(full_diff .- all_local_diff))

            #if (tree_LL-old_LL) + (tree_prior-old_prior) < -8
            if min_local_diff > 0.1 
                println("full_diff: $full_diff")
                println("local_diff: $local_diff")
                println("min_local_diff: $min_local_diff")

                println("prior_diff: $((tree_prior-old_prior))")
                println("local_prior_diff: $(priors[state_index] - priors[A[ai]])")

                println("prior_err: $(abs((tree_prior-old_prior) - (priors[state_index] - priors[A[1]])))")

                println("LL_diff: $(tree_LL-old_LL)")
                println("local_LL_diff: $(likelihoods[state_index] - likelihoods[A[ai]])")
                assert(false)
            end
        end
    end
end



function sample_eta(model::ModelState,
                    model_spec::ModelSpecification,
                    data::DataState,
                    hmc_iterations::Int64;
                    Temp::Float64 = 1.0)

    tree  = model.tree
    N::Int = (length(tree.nodes) + 1) / 2
    M, S = size(data.reference_counts)
    eta = zeros(S*(N-1))

    num_iterations = 10


    for j = N+1:2N-1
        eta[1 + (j-N-1)*S : (j-N)*S] = tree.nodes[j].state
    end

    function eta_density(eta::Vector{Float64})
        for j = N+1:2N-1
            tree.nodes[j].state = eta[1 + (j-N-1)*S : (j-N)*S]
        end
        e_pdf = eta_logpdf(model, model_spec, data, Temp=Temp)
        return e_pdf
    end

    function eta_grad(eta::Vector{Float64})
        for j = N+1:2N-1
            tree.nodes[j].state = eta[1 + (j-N-1)*S : (j-N)*S]
        end
        grad = eta_log_gradient(model, model_spec, data, Temp=Temp)
        return grad
    end

    hmcopts = @options numsteps=8 stepsize=0.01 transformation=ReducedNaturalTransformation
    refopts = @options m=2 w=0.1 refractive_index_ratio=1.3 transformation=ReducedNaturalTransformation #verify_gradient=true

    if rand() < 0.5
        for i = 1:hmc_iterations
            eta = refractive_sampler(eta, eta_density, eta_grad, refopts)
        end
    else
        for i = 1:hmc_iterations
            eta = hmc_sampler(eta, eta_density, eta_grad, hmcopts)
        end

    end
#    verify_gradient = true
#    if verify_gradient
#        println("eta: $eta")
#        grad = eta_grad(eta)
#        epsilon = 10.0^-5
#
#        f1 = eta_density(eta)
#        for i = 1:length(eta)
#            eta_new = copy(eta)
#            eta_new[i] = eta_new[i] + grad[i]/abs(grad[i])*epsilon
#            f2 = eta_density(eta_new)
#            println("grad $i: $(norm(grad[i])*epsilon)")
#            println("agrad $i: $( (f2-f1))")
#        end
#    end
    
 
    for j = N+1:2N-1
        tree.nodes[j].state = eta[1 + (j-N-1)*S : (j-N)*S]
    end
end

function sample_assignments(model::ModelState,
                            model_spec::ModelSpecification,
                            data::DataState,
                            num_iterations::Int64;
                            Temp::Float64 = 1.0)

    tree = model.tree
    N::Int = (length(tree.nodes) + 1) / 2
    M,S = size(data.reference_counts)

    t = compute_times(model)
    Tau = compute_taus(model)
    phi = compute_phis(model)

    Z = model.Z
    U = zeros(Int64, N-1)
    for i=1:length(Z)
        U[Z[i]-N] += 1
    end 
    U = U .- 1

    for iter = 1:num_iterations    
        for i = 1:M
            cur_z = Z[i]-N
            z_probs = z_logpdf(model, model_spec, data, i, U, t, Tau, phi, Temp=Temp)

#            full_logpdf = k -> (model.Z[i] = k+N; full_pdf(model, model_spec, data))
#            full_z_probs = [full_logpdf(k) for k = 1:N-1]
#            z_probs -= maximum(z_probs)
#            full_z_probs -= maximum(full_z_probs)
#            println("full_z_probs: $full_z_probs")
#            println("z_probs: $z_probs")
#            @assert false


            new_z = rand(Categorical(exp_normalize(z_probs)))
            U[cur_z] -= 1
            U[new_z] += 1
            Z[i] = new_z+N
        end
    end
end

function compute_assignment_probs(model::ModelState,
                                  model_spec::ModelSpecification,
                                  data::DataState,
                                  Temp::Float64 = 1.0)

    tree = model.tree
    N::Int = (length(tree.nodes) + 1) / 2
    M,S = size(data.reference_counts)

    t = compute_times(model)
    Tau = compute_taus(model)
    phi = compute_phis(model)

    Z = model.Z
    U = zeros(Int64, N-1)
    for i=1:length(Z)
        U[Z[i]-N] += 1
    end 
    U = U .- 1

    z_probs = zeros(M,N-1)

    for i = 1:M
        cur_z = Z[i]-N
        z_probs[i,:] = z_logpdf(model, model_spec, data, i, U, t, Tau, phi, Temp=Temp)
    end

    return z_probs
end
function sample_num_leaves(model::ModelState,
                           model_spec::ModelSpecification,
                           data::DataState,
                           num_iterations::Int64;
                           Temp::Float64 = 1.0)

    tree = model.tree
    lambda = model.lambda
    alpha = model.alpha

    _2Nm1 = length(tree.nodes)
    N::Int = (_2Nm1+1)/2
    M,S = size(data.reference_counts)

    root = FindRoot(model.tree, 1)
    root_index = root.index
   
    # W = (K-1, K) 
    if rand() < 0.5
        model_star = draw_neighboring_tree(model, model_spec, data, N-1)

        for i = 1:num_iterations
            mcmc_sweep(model_star, model_spec, data)
        end 

    # W = (K, K+1) 
    else
        model_star = draw_neighboring_tree(model, model_spec, data, N+1)

        for i = 1:num_iterations
            mcmc_sweep(model_star, model_spec, data)
        end 

    end


end

function draw_neighboring_tree(model::ModelState,
                               model_spec::ModelSpecification,
                               data::DataState,
                               new_N::Int64;
                               Temp::Float64 = 1.0)
    tree = model.tree
    root = FindRoot(tree,1)
    _2Nm1 = length(tree.nodes)
    N::Int = (_2Nm1+1)/2
    
    M,S = size(data.reference_counts)

    ntree = Tree{Vector{Float64}}()
    ntree.nodes = Array(TreeNode{Vector{Float64}}, 2*new_N-1)
 

    new_indices = [1:2*new_N-1]


    queue = Array(Tuple,0)
    push!(queue, (root.index, new_N, 0, true))


    while length(queue) > 0
        cur_index, N_cur, parent_nindex, is_right = shift!(queue)

        parent = parent_nindex == 0 ? Nil() : ntree.nodes[parent_nindex]

        new_index = pop!(new_indices)
        if cur_index > 0 
            cur = tree.nodes[cur_index]


            p_new = 1-cur.rhot


            p_r = cur.rho
            p_l = (1-cur.rho)


            ntree.nodes[new_index] = TreeNode(cur.state, new_index)
            ntree.nodes[new_index].rhot = cur.rhot
            ntree.nodes[new_index].rho = cur.rho
        else
            # new node that differs from given tree
            xi = 1 - 2/(N_cur+1)
            nutd = xi < rand() ? 1.0 : rand(Beta(xi, 1.0))
            nu = rand()
            eta = rand(Beta(alpha*nu+1, alpha*(1-nu)+1), S)

            p_new = 1-nutd
            p_r = nu
            p_l = 1-nu

            ntree.nodes[new_index] = TreeNode(eta, new_index)
            ntree.nodes[new_index].rhot = nutd
            ntree.nodes[new_index].rho = nu

        end

        if N_cur == 1
            ntree.nodes[new_index].children[1] = Nil()
            ntree.nodes[new_index].children[2] = Nil()
        end

        ntree.nodes[new_index].parent = parent
        if parent != Nil()
            parent.children[2-is_right] = ntree.nodes[new_index]
        end


        if N_cur > 1

            N_n = 0*rand(Binomial(N_cur-2, p_new))
            N_cur -= N_n

            if N_n > 0
                nutd_index = pop!(new_indices)
                xi = 1 - 2/(N_n+1)
                nutd = xi < rand() ? 1.0 : rand(Beta(xi, 1.0))
                nu = rand()
                eta = rand(Beta(alpha*nu+1, alpha*(1-nu)+1), S)

                ntree.nodes[nutd_index] = TreeNode(eta, nutd_index)
                ntree.nodes[nutd_index].rhot = nutd
                ntree.nodes[nutd_index].rho = nu

                ntree.nodes[nutd_index].parent = parent
                if parent != Nil()
                    parent.children[2-is_right] = ntree.nodes[nutd_index]
                end

                ntree.nodes[nutd_index].children[2] = ntree.nodes[new_index]
                ntree.nodes[new_index].parent = ntree.nodes[nutd_index]
                if N_n > 0
                    push!(queue, (0, N_n, nutd_index, true))
                end
            end

            N_r = N_cur > 2 ? rand(Binomial(N_cur-2, p_r))+1 : 1
            N_l = N_cur - N_r

            l = cur.children[2]
            r = cur.children[1]

            l_index = l == Nil() ? 0 : l.index
            r_index = r == Nil() ? 0 : r.index

            if N_l > 0
                push!(queue, (l_index, N_l, new_index, false))
            end
            if N_r > 0
                push!(queue, (r_index, N_r, new_index, true))
            end
        end

    end

    nindices = [x.index for x in ntree.nodes]

    nroot = ntree.nodes[2* new_N-1]
    if nroot.parent != Nil()
        nroot = nroot.parent
    end 
    (new_tree, index_map) = MakeReindexedTree(ntree, nroot.index, N) 
    new_root = index_map[nroot.index]

    new_model = copy(model)
    new_model.tree = new_tree

    times = compute_times(new_model)
    Tau = compute_taus(new_model)
    phi = compute_phis(new_model)
    # dummy U set to ones as z_logpdf takes into account
    # the fact that we shouldn't leave clusters empty (but we don't want that here)
    U = ones(Int64,length(model.Z))

    indices = GetLeafToRootOrdering(new_tree, new_root) 
    new_model.Z = ones(Int64, length(model.Z)) + new_N

    Z_logpdfs = zeros(new_N-1, M)
    for m = 1:M
        Z_logpdfs[:,m] = z_logpdf(new_model, model_spec, data, m, U, times, Tau, phi, Temp=Temp) 
    end

    # Assign mutations to clusters
    for m = 1:M
        i = rand(Categorical(exp_normalize(Z_logpdfs[:,m])))
        new_model.Z[m] = i+new_N
    end

 
    return new_model 
end


function draw_neighboring_tree_remove_insert(model::ModelState,
                                             model_spec::ModelSpecification,
                                             data::DataState,
                                             new_N::Int64;
                                             Temp::Float64 = 1.0)
    tree = model.tree
    root = FindRoot(tree,1)
    N::Int = (length(tree.nodes) + 1) / 2

    @assert abs(new_N - N) == 1
    M,S = size(data.reference_counts)

    if new_N > N
        grafted_leaf_index = 2N
        grafted_parent_index = 2N+1

        grafted_leaf = TreeNode(zeros(S), grafted_leaf_index)
       
        nutd = 0.5 < rand() ? 1.0 : rand() 
        nu = rand()
        eta = rand(Beta(alpha*nu+1, alpha*(1-nu)+1), S)
        grafted_parent = TreeNode(eta, grafted_parent_index)
        grafted_parent.rhot = nutd
        grafted_parent.rho = nu
        grafted_parent.children[1] = grafted_leaf
        grafted_parent.children[2] = Nil()
        grafted_parent.parent = Nil()
        grafted_leaf.children[1] = Nil()
        grafted_leaf.children[2] = Nil()
        grafted_leaf.parent = grafted_parent

        new_model = copy(model)
        push!(new_model.tree.nodes, grafted_leaf)
        push!(new_model.tree.nodes, grafted_parent)

        #pick a random right child
        insert_location = rand(1:2N-1)
        while true
            cur = tree.nodes[insert_location]
            parent = cur.parent
            if parent.children[1] == cur
                break
            end 
            insert_location = rand(1:2N-1)
        end

        temp_node = tree.nodes[insert_location]        

        left_path_length = 0
        while temp_node != Nil()
            temp_node = temp_node.children[2]
            left_path_length += 1
        end

        InsertAndDemoteLeft!(new_model.tree, grafted_parent_index, insert_location, rand(1:left_path_length))

        new_root = FindRoot(new_model.tree, 1)
        new_tree, index_map = MakeReindexedTree(new_model.tree, new_root.index, N)
        new_model.tree = new_tree
    else
        removal_index = rand(N+1:2N-1)

        new_model = copy(model)
        println("removal_index: $removal_index")
        println("$([x.index for x in tree.nodes[removal_index].children])")
        RemoveAndPromoteRight!(new_model.tree, removal_index)


        existing_index = N + find([N+1:2N-1] .!= removal_index)[1]
        println("N: $N")
        println("existing index: $existing_index")
        new_root = FindRoot(new_model.tree, existing_index)
        new_tree, index_map = MakeReindexedTree(new_model.tree, new_root.index, N)
        new_model.tree = new_tree
    end
 
            ZZ, leaf_times, Etas, inds = model2array(new_model, return_leaf_times=true)
            new_u = zeros(Int64, 2(N+1)-1)
            for i=1:length(new_model.Z)
                x = new_model.Z[i]
                new_u[x] += 1
            end 
            p_dendrogram2 = dendrogram(ZZ,new_u[inds], plot=false, sorted_inds=inds, leaf_times=leaf_times)

        display(p_dendrogram2)

    times = compute_times(new_model)
    Tau = compute_taus(new_model)
    phi = compute_phis(new_model)
    # dummy U set to ones as z_logpdf takes into account
    # the fact that we shouldn't leave clusters empty (but we don't want that here)
    U = ones(Int64,length(model.Z))

    indices = GetLeafToRootOrdering(new_tree, index_map[new_root.index]) 
    new_model.Z = ones(Int64, length(model.Z)) + new_N

    Z_logpdfs = zeros(new_N-1, M)
    for m = 1:M
        Z_logpdfs[:,m] = z_logpdf(new_model, model_spec, data, m, U, times, Tau, phi, Temp=Temp) 
    end

    # Assign mutations to clusters
    for m = 1:M
        i = rand(Categorical(exp_normalize(Z_logpdfs[:,m])))
        new_model.Z[m] = i+new_N
    end

 
    return new_model 
end


# Integrate exp(f) in a numerically stable way
function int_exp(f::Function, a::Float64, b::Float64)
    fx::Float64 = f(0.5(a+b))::Float64
    g = (t::Float64) -> exp(f(t)::Float64-fx)
    (integral, error) = adaptive_gauss_kronrod(g,a,b,1e-10,50)

    (integral,fx)
end

function sample_time(f::Function,
                     a::Float64,
                     b::Float64,
                     num_iter::Int64,
                     step_scale::Float64)
    x = 0.5(a+b)
    fx = f(x)
    w = (b-a)*step_scale
    for i = 1:num_iter
        (x,fx) = slice_sampler(x, f, w, 10000, a, b, fx)
    end
    return x
end

#end #end profile
