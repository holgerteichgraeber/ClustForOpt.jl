
"""
    sort_centers(centers::Array,weights::Array)
- centers: hours x days e.g.[24x9]
- weights: days [e.g. 9], unsorted
sorts the centers by weights from largest to smallest
"""
function sort_centers(centers::Array,
                      weights::Array
                      )
  i_w = sortperm(-weights)   # large to small (-)
  weights_sorted = weights[i_w]
  centers_sorted = centers[:,i_w]
  return centers_sorted, weights_sorted
end # function

"""
    z_normalize(data::ClustData;scope="full")
scope: "full", "sequence", "hourly"
"""
function z_normalize(data::ClustData;
                    scope="full"
                    )
 data_norm = Dict{String,Array}()
 mean= Dict{String,Array}()
 sdv= Dict{String,Array}()
 for (k,v) in data.data
   data_norm[k],mean[k],sdv[k] = z_normalize(v,scope=scope)
 end
 return ClustData(data.region,data.years,data.K,data.T,data_norm,data.weights,data.k_ids;delta_t=data.delta_t,mean=mean,sdv=sdv)
end

"""
     z_normalize(data::Array;scope="full")
z-normalize data with mean and sdv by hour
data: input format: (1st dimension: 24 hours, 2nd dimension: # of days)
scope: "full": one mean and sdv for the full data set; "hourly": univariate scaling: each hour is scaled seperately; "sequence": sequence based scaling
"""
function z_normalize(data::Array;
                    scope="full"
                    )
  if scope == "sequence"
    seq_mean = zeros(size(data)[2])
    seq_sdv = zeros(size(data)[2])
    data_norm = zeros(size(data))
    for i=1:size(data)[2]
      seq_mean[i] = mean(data[:,i])
      seq_sdv[i] = StatsBase.std(data[:,i])
      isnan(seq_sdv[i]) &&  (seq_sdv[i] =1)
        data_norm[:,i] = data[:,i] .- seq_mean[i]
      # handle edge case sdv=0
      if seq_sdv[i]!=0
        data_norm[:,i] = data_norm[:,i]./seq_sdv[i]
      end
    end
    return data_norm,seq_mean,seq_sdv
  elseif scope == "hourly"
    hourly_mean = zeros(size(data)[1])
    hourly_sdv = zeros(size(data)[1])
    data_norm = zeros(size(data))
    for i=1:size(data)[1]
      hourly_mean[i] = mean(data[i,:])
      hourly_sdv[i] =  StatsBase.std(data[i,:])
      data_norm[i,:] = data[i,:] .- hourly_mean[i]
      # handle edge case sdv=0
      if hourly_sdv[i] !=0
        data_norm[i,:] = data_norm[i,:]./hourly_sdv[i]
      end
    end
    return data_norm, hourly_mean, hourly_sdv
  elseif scope == "full"
    hourly_mean = mean(data)*ones(size(data)[1])
    hourly_sdv = StatsBase.std(data)*ones(size(data)[1])
    # handle edge case sdv=0
    if hourly_sdv[1] != 0
      data_norm = (data.-hourly_mean[1])/hourly_sdv[1]
    else
      data_norm = (data.-hourly_mean[1])
    end
    return data_norm, hourly_mean, hourly_sdv #TODO change the output here to an immutable struct with three fields - use struct - "composite type"
  else
    error("scope _ ",scope," _ not defined.")
  end
end # function z_normalize

"""
    undo_z_normalize(data_norm_merged::Array,mn::Dict{String,Array},sdv::Dict{String,Array};idx=[])
provide idx should usually be done as default within function call in order to enable sequence-based normalization, even though optional.
"""
function undo_z_normalize(data_norm_merged::Array,mn::Dict{String,Array},sdv::Dict{String,Array};idx=[])
  T = div(size(data_norm_merged)[1],length(keys(mn))) # number of time steps in one period. div() is integer division like in c++, yields integer (instead of float as in normal division)
  0 != rem(size(data_norm_merged)[1],length(keys(mn))) && error("dimension mismatch") # rem() checks the remainder. If not zero, throw error.
  data_merged = zeros(size(data_norm_merged))
  i=0
  for (attr,mn_a) in mn
    i+=1
    data_merged[(1+T*(i-1)):(T*i),:]=undo_z_normalize(data_norm_merged[(1+T*(i-1)):(T*i),:],mn_a,sdv[attr];idx=idx)
  end
  return data_merged
end


"""
    undo_z_normalize(data_norm, mn, sdv; idx=[])
undo z-normalization data with mean and sdv by hour
normalized data: input format: (1st dimension: 24 hours, 2nd dimension: # of days)
hourly_mean ; 24 hour vector with hourly means
hourly_sdv; 24 hour vector with hourly standard deviations
"""
function undo_z_normalize(data_norm::Array, mn::Array, sdv::Array; idx=[])
  if size(data_norm,1) == size(mn,1) # hourly and full- even if idx is provided, doesn't matter if it is hourly
    data = data_norm .* sdv + mn * ones(size(data_norm)[2])'
    return data
  elseif !isempty(idx) && size(data_norm,2) == maximum(idx) # sequence based
    # we obtain mean and sdv for each day, but need mean and sdv for each centroid - take average mean and sdv for each cluster
    summed_mean = zeros(size(data_norm,2))
    summed_sdv = zeros(size(data_norm,2))
    for k=1:size(data_norm,2)
      mn_temp = mn[idx.==k]
      sdv_temp = sdv[idx.==k]
      summed_mean[k] = sum(mn_temp)/length(mn_temp)
      summed_sdv[k] = sum(sdv_temp)/length(sdv_temp)
    end
    data = data_norm * Diagonal(summed_sdv) +  ones(size(data_norm,1)) * summed_mean'
    return data
  elseif isempty(idx)
    error("no idx provided in undo_z_normalize")
  end
end

"""
     sakoe_chiba_band(r::Int,l::Int)
calculates the minimum and maximum allowed indices for a lxl windowed matrix
for the sakoe chiba band (see Sakoe Chiba, 1978).
Input: radius r, such that |i(k)-j(k)| <= r
length l: dimension 2 of the matrix
"""
function sakoe_chiba_band(r::Int,l::Int)
  i2min = Int[]
  i2max = Int[]
  for i=1:l
    push!(i2min,max(1,i-r))
    push!(i2max,min(l,i+r))
  end
  return i2min, i2max
end

"""
     calc_SSE(data::Array,centers::Array,assignments::Array)
calculates Sum of Squared Errors between cluster representations and the data
"""
function calc_SSE(data::Array,centers::Array,assignments::Array)
  k=size(centers,2) # number of clusters
  n_periods =size(data,2)
  SSE_sum = zeros(k)
  for i=1:n_periods
    SSE_sum[assignments[i]] += sqeuclidean(data[:,i],centers[:,assignments[i]])
  end
  return sum(SSE_sum)
end # calc_SSE

"""
    calc_SSE(data::Array,centers::Array,assignments::Array)
calculates Sum of Squared Errors between cluster representations and the data
"""
function calc_SSE(data::Array,assignments::Array)
  centers=calc_centroids(data, assignments)
  k=size(centers,2) # number of clusters
  n_periods =size(data,2)
  SSE_sum = zeros(k)
  for i=1:n_periods
    SSE_sum[assignments[i]] += sqeuclidean(data[:,i],centers[:,assignments[i]])
  end
  return sum(SSE_sum)
end # calc_SSE

"""
    calc_centroids(data::Array,assignments::Array)
Given the data and cluster assignments, this function finds
the centroid of the respective clusters.
"""
function calc_centroids(data::Array,assignments::Array)
  K=maximum(assignments) #number of clusters
  n_per_period=size(data,1)
  n_periods =size(data,2)
  centroids=zeros(n_per_period,K)
  for k=1:K
    centroids[:,k]=sum(data[:,findall(assignments.==k)];dims=2)/length(findall(assignments.==k))
  end
  return centroids
end

"""
     calc_medoids(data::Array,assignments::Array)
Given the data and cluster assignments, this function finds
the medoids that are closest to the cluster center.
"""
function calc_medoids(data::Array,assignments::Array)
  K=maximum(assignments) #number of clusters
  n_per_period=size(data,1)
  n_periods =size(data,2)
  SSE=Float64[]
  for i=1:K
    push!(SSE,Inf)
  end
  centroids=calc_centroids(data,assignments)
  medoids=zeros(n_per_period,K)
  # iterate through all data points
  for i=1:n_periods
    d = sqeuclidean(data[:,i],centroids[:,assignments[i]])
    if d < SSE[assignments[i]] # if this data point is closer to centroid than the previously visited ones, then make this the medoid
      medoids[:,assignments[i]] = data[:,i]
      SSE[assignments[i]]=d
    end
  end
  return medoids
end

#"""
# Not used in literature. Only uncomment if test added.
#     resize_medoids(data::Array,centers::Array,weights::Array,assignments::Array)
#Takes in centers (typically medoids) and normalizes them such that for all clusters the average of the cluster is the same as the average of the respective original data that belongs to that cluster.
#In order to use this method of the resize function, add assignments to the function call (e.g. clustids[5,1]).
#"""
#function resize_medoids(data::Array,centers::Array,weights::Array,assignments::Array)#
#    new_centers = zeros(centers)
#    for k=1:size(centers)[2] # number of clusters
#       is_in_k = assignments.==k
#       n = sum(is_in_k)
#       new_centers[:,k]=resize_medoids(reshape(data[:,is_in_k],:,n),reshape(centers[:,k] , : ,1),[1.0])# reshape is used for the side case with only one vector, so that resulting vector is 24x1 instead of 24-element
#    end
#    return new_centers
#end


"""
    resize_medoids(data::Array,centers::Array,weights::Array)
This is the DEFAULT resize medoids function
Takes in centers (typically medoids) and normalizes them such that the yearly average of the clustered data is the same as the yearly average of the original data.
"""
function resize_medoids(data::Array,centers::Array,weights::Array)
    mu_data = sum(data)
    mu_clust = 0
    w_tot=sum(weights)
    for k=1:size(centers)[2]
      mu_clust += weights[k]/w_tot*sum(centers[:,k]) # weights[k]>=1
    end
    mu_clust *= size(data)[2]
    mu_data_mu_clust = mu_data/mu_clust
    new_centers = centers* mu_data_mu_clust
    return new_centers
end

"""
     resize_medoids(data::Array,centers::Array,weights::Array)
This is the DEFAULT resize medoids function
Takes in centers (typically medoids) and normalizes them such that the yearly average of the clustered data is the same as the yearly average of the original data.
"""
function resize_medoids(data::ClustData,centers::Array,weights::Array)
    (data.T * length(keys(data.data)) != size(centers,1) ) && error("dimension missmatch between full input data and centers")
    centers_res = zeros(size(centers))
    # go through the attributes within data
    i=0
    for (k,v) in data.data
      i+=1
      # calculate resized centers for each attribute
      centers_res[(1+data.T*(i-1)):(data.T*i),:] = resize_medoids(v,centers[(1+data.T*(i-1)):(data.T*i),:],weights)
    end
    return centers_res
end


"""
    calc_weights(clustids::Array{Int}, n_clust::Int)
Calculates weights for clusters, based on clustids that are assigned to a certain cluster. The weights are absolute:    weights[i]>=1
"""
function calc_weights(clustids::Array{Int}, n_clust::Int)
    weights = zeros(n_clust)
    for j=1:length(clustids)
        weights[clustids[j]] +=1
    end
    return weights
end

"""
    set_clust_config(;kwargs...)
Add kwargs to a new Dictionary with the variables as entries
"""
function set_clust_config(;kwargs...)
  #Create new Dictionary
  config=Dict{String,Any}()
  # Loop through the kwargs and write them into Dictionary
  for kwarg in kwargs
    config[String(kwarg[1])]=kwarg[2]
  end
  # Return Directory with the information of kwargs
  return config
end

"""
    run_pure_clust(data::ClustData; norm_op::String="zscore", norm_scope::String="full", method::String="kmeans", representation::String="centroid", n_clust_1::Int=5, n_clust_2::Int=3, n_seg::Int=data.T, n_init::Int=100, iterations::Int=300, attribute_weights::Dict{String,Float64}=Dict{String,Float64}(), clust::Array{String,1}=Array{String,1}(), get_all_clust_results::Bool=false, kwargs...)
Replace the original timeseries of the attributes in clust with their clustered value
"""
function run_pure_clust(data::ClustData;
                            norm_op::String="zscore",
                            norm_scope::String="full",
                            method::String="kmeans",
                            representation::String="centroid",
                            n_clust::Int=5,
                            n_seg::Int=data.T,
                            n_init::Int=100,
                            iterations::Int=300,
                            attribute_weights::Dict{String,Float64}=Dict{String,Float64}(),
                            clust::Array{String,1}=Array{String,1}(),
                            get_all_clust_results::Bool=false,
                            kwargs...)
  clust_result=run_clust(data;norm_op=norm_op,norm_scope=norm_scope,method=method,representation=representation,n_clust=n_clust,n_init=n_init,iterations=iterations,attribute_weights=attribute_weights)
  clust_data=clust_result.clust_data
  mod_data=deepcopy(data.data)
  for i in 1:clust_data.K
    index=findall(clust_data.k_ids.==i)
    for name in keys(mod_data)
      att=split(name,"-")[1]
      if name in clust || att in clust
        mod_data[name][:,index]=repeat(clust_data.data[name][:,i], outer=(1,length(index)))
      end
    end
  end
  return ClustResult(ClustData(data.region, data.years, data.K, data.T, mod_data, data.weights, data.k_ids;delta_t=data.delta_t),clust_result.cost, clust_result.config)
end

"""
    quantile_durationCurve(c::Array,bin_dict::Dict,size_int)
Compute the share of entries below a certain threshold for each value in input dictionary. Results correspond to points on a normalized duration curve.
"""
function quantile_durationCurve(c::Array,bin_dict::Dict,size_int)
    h = Dict()
    for bin in keys(bin_dict)
        h[bin] = length(filter(x -> x >= bin_dict[bin],c))/size_int
    end
    return h
end
