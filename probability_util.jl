require("model.jl")

# Utility probability functions
function normal_logpdf(x, sigma)
    -x.*x/(2sigma*sigma) - 0.5log(2pi) - log(sigma)
end

function poisson_logpdf(k,lambda)
    -lambda + k*log(lambda) - sum(log(1:k))
end

# Must be normalized for use in expanding dimensions for variable dimension slice sampling
function t_logpdf(x, nu)
    -x.*x/(2nu*nu) - 0.5log(2pi) - log(nu)
    #lgamma(0.5*(nu+1)) - lgamma(0.5nu) - 0.5*log(nu*pi) - 0.5*(nu+1)*log(1+x*x/nu)
end

# Sigma = I
function multivariate_t_logpdf(x_squared_norm, p, nu)
   lgamma(0.5*(nu+p)) - lgamma(0.5nu) - 0.5p*log(nu*pi) - 0.5*(nu+p)*log(1 + x_squared_norm/nu)
end

function log_logit(effect, y)
    value = 0.0
    if y == 1
        value = -log(1 + exp(-effect))
        if isinf(value)
            value = effect
        end
    elseif y == 0
        value = -effect - log(1 + exp(-effect))
        if isinf(value)
            value = 0.0
        end
    end
    return value
end

function log_predictive(effect)
    -log(1+exp(-effect))
end

# Probability Manipulation

function logsumexp(x)
    max_x = max(x)
    xp = x - max_x
    log(sum(exp(xp))) + max_x
end

function exp_normalize(x)
    xp = x - max(x)
    exp_x = exp(xp)
    exp_x / sum(exp_x)
end

# Basic Sampling

function randmult(x)
    v = cumsum(x)
    assert( abs(v[end] - 1.0) < 10.0^-8)
#    if v[end] != 1.0
#        println("v[end]: ", v[end])
#        assert(v[end] == 1.0)
#    end

    u = rand()
    i = 1
    while u > v[i]
        i += 1
    end
    i
end

function randpois(lambda)
    L = exp(-lambda)
    k = 0
    p = 1.0
    while p > L
        k += 1
        p = p * rand()
    end
    k - 1
end

# Prediction

# test metrics.  AUC computation trick found in Konstantina Palla's ILA code
function error_and_auc(logit_args::Array{ Array{Float64, 1}, 2},
                       data::DataState)

    (N,N) = size(data.Ytrain)

#    minargs = min( [ min(logit_args[i,j]) for i = 1:N, j = 1:N])
#    maxargs = max( [ max(logit_args[i,j]) for i = 1:N, j = 1:N])
#
#    bias_range = linspace(-maxargs-2,-minargs+2,100)
#
#
#    roc_false_positives = zeros(Int, length(bias_range))
#    roc_true_positives = zeros(Int, length(bias_range))
#    roc_positives = zeros(Int, length(bias_range))
#
    probs = zeros(N,N)
    train01error = 0
    test01error = 0

    for i = 1:N
        for j = 1:N
            logit_arg_list = logit_args[i,j]
            (prob, logprob) = averaged_prediction(logit_arg_list)
            probs[i,j] = prob

            if data.Ytrain[i,j] >= 0
                train01error += round(prob) != data.Ytrain[i,j]
            elseif data.Ytest[i,j] >= 0
                test01error += round(prob) != data.Ytest[i,j]

#                for bias_ind = 1:length(bias_range)
#                    bias = bias_range[bias_ind]
#
#                    (prob, logprob) = averaged_prediction(logit_arg_list + bias)
#
#                    if round(prob) == 1
#                        roc_positives[bias_ind] += 1
#                        if data.Ytest[i,j] == 1
#                            roc_true_positives[bias_ind] += 1
#                        else
#                            roc_false_positives[bias_ind] += 1
#                        end
#                    end
#
#                end
            end 
        end
    end

    Itrain = find(data.Ytrain .>= 0)
    Itest = find(data.Ytest .>= 0)
    test_pos = find(data.Ytest .== 1)
    test_neg = find(data.Ytest .== 0)

    test_probs = probs[Itest]
    p = sortperm(test_probs)
    Ytest_sorted = data.Ytest[Itest[p]]

    num_links = sum(Ytest_sorted .== 1)
    num_nonlinks = sum(Ytest_sorted .== 0)

    # sum of ranks (minus correction) gives the true positive count, false positive count area
    count_under_curve = sum(find(Ytest_sorted .== 1)) - (num_links*(num_links+1))/2

    auc = (count_under_curve ) / (num_links * num_nonlinks)

#    roc_tpr = roc_true_positives ./ length(test_pos)
#    roc_fpr = roc_false_positives ./ length(test_neg)
#
#    auc = trapz(roc_fpr, roc_tpr) 
    train_error_rate = train01error / length(Itrain)
    test_error_rate = test01error / length(Itest)


    (train_error_rate, test_error_rate, auc)
end

function averaged_prediction(logit_arg::Array{Float64, 1})

    logprobs = log_predictive(logit_arg)
    logprob = logsumexp(logprobs) - log(length(logprobs))
    (exp(logprob), logprob)
end



function trapz(x::Array{Float64,1}, y::Array{Float64,1})
    assert(length(x) == length(y))

    inds = find(!isnan(x) .* !isinf(x) .* !isnan(y) .* !isinf(y))

    xx = x[inds]
    yy = y[inds]

    ly = yy[1:end-1]
    ry = yy[2:end]
   
    lx = xx[1:end-1]
    rx = xx[2:end] 

    sum(0.5*(ry + ly) .* (rx-lx))
end

