/*
* Copyright 2019-2020 NVIDIA CORPORATION.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

#pragma once

#include <exception>
#include <memory>
#include <string>
#include <unordered_map>

#include <claraparabricks/genomeworks/cudamapper/types.hpp>
#include <claraparabricks/genomeworks/utils/allocator.hpp>
#include <claraparabricks/genomeworks/cudamapper/index.hpp>

namespace claraparabricks
{

namespace genomeworks
{

namespace io
{
class FastaParser;
} // namespace io

namespace cudamapper
{

class IndexHostCopyBase;
class HostIndexCache;

/// CacheType - Specifies if query or target cache
enum class CacheType
{
    query_cache,
    target_cache
};

/// DeviceIndexCache - Owns copies of indices on device
///
/// These object are created by HostIndexCache::start_copying_indices_to_device()
class DeviceIndexCache
{
public:
    /// \brief Constructor
    /// \param cache_type
    /// \param host_cache HostIndexCache that created this object
    DeviceIndexCache(CacheType cache_type,
                     HostIndexCache* host_cache);

    DeviceIndexCache(const DeviceIndexCache&) = delete;
    DeviceIndexCache(DeviceIndexCache&&)      = delete;
    DeviceIndexCache& operator=(const DeviceIndexCache&) = delete;
    DeviceIndexCache& operator=(DeviceIndexCache&&) = delete;

    /// \brief Destructor
    ~DeviceIndexCache();

    /// \brief Adds index to host, should only be called by HostIndexCache::start_copying_indices_to_device()
    /// \param index_descriptor
    /// \param device_index
    void add_index(IndexDescriptor index_descriptor,
                   std::shared_ptr<Index> device_index);

    /// \brief Returns requested index
    /// Calling this function before wait_for_data_to_be_ready() results in an exception
    /// \param index_descriptor
    /// \throw IndexNotFoundException if requested index is not cached
    /// \throw DeviceCacheNotReadyException is cache is not ready, i.e. wait_for_data_to_be_ready() has not been called yet
    /// \return requested index
    std::shared_ptr<Index> get_index(IndexDescriptor index_descriptor) const;

    /// \brief Returns requested index, returned index might not be ready and has to be synchronized directly
    /// \param index_descriptor
    /// \throw IndexNotFoundException if requested index is not cached
    /// \return requested index
    std::shared_ptr<Index> get_index_no_check_if_ready(IndexDescriptor index_descriptor) const;

    /// \brief Returns whether given index is present in cache
    /// \param index_descriptor
    /// \return is given index present in cache
    bool has_index(IndexDescriptor index_descriptor) const;

    /// \brief Waits for indices to be copied from host memory. Must be called before get_index()
    void wait_for_data_to_be_ready();

    /// \brief Returns whether indices have been copied to device and get_index() can be called, i.e. whether wait_for_data_to_be_ready() has already been called
    /// \return whether indices have been copied to device
    bool is_ready() const;

private:
    using device_cache_t = std::unordered_map<IndexDescriptor,
                                              std::shared_ptr<Index>,
                                              IndexDescriptorHash>;

    device_cache_t cache_;

    CacheType cache_type_;
    // HostIndexCache which created this DeviceIndexCache
    HostIndexCache* host_cache_;

    // wait_for_data_to_be_ready
    bool is_ready_;
};

/// HostIndexCache - Creates indices, stores them in host memory and on demands moves them to device memory
///
/// Class contains separate caches for query and target. The user chooses between query and target by specifying CacheType in function calls.
/// The user generates indices and stores them in host memory using generate_content(). The user then copies some of those indices
/// to device memory using start_copying_indices_to_device() and the function returns a pointer to DeviceIndexCache. To wait for indices to be
/// fully copied one should call DeviceIndexCache::wait_for_data_to_be_ready().
/// It is user's responsibility to make sure that indices requested by start_copying_indices_to_device() were generated by generate_content().
/// Memory copy to device is done asynchronously, the user should make sure that every call to start_copying_indices_to_device() is
/// accompanied by a call DeviceIndexCache::wait_for_data_to_be_ready().
/// The class tries to minimize the number of index creation and movemens, e.g. by reusing already existing indices, but not guarantees are given.
class HostIndexCache
{
public:
    /// \brief Constructor only initializes cache, no index is generated at this point, generate_content() does that
    ///
    /// \param same_query_and_target true means that both query and target files are the same, meaning that if some index exists in query cache it can also be used by target cache directly
    /// \param allocator allocator to use for device arrays
    /// \param query_parser
    /// \param target_parser
    /// \param kmer_size see Index
    /// \param window_size see Index
    /// \param hash_representations see Index
    /// \param filtering_parameter see Index
    /// \param cuda_stream_generation index generation is done one this stream, device memory in resulting device copies of index will only we freed once all previously scheduled work on this stream has finished
    /// \param cuda_stream_copy D2H and H2D copies of indices will be done on this stream, device memory in resulting device copies of index will only we freed once all previously scheduled work on this stream has finished
    HostIndexCache(bool same_query_and_target,
                   genomeworks::DefaultDeviceAllocator allocator,
                   std::shared_ptr<genomeworks::io::FastaParser> query_parser,
                   std::shared_ptr<genomeworks::io::FastaParser> target_parser,
                   std::uint64_t kmer_size,
                   std::uint64_t window_size,
                   bool hash_representations           = true,
                   double filtering_parameter          = 1.0,
                   cudaStream_t cuda_stream_generation = 0,
                   cudaStream_t cuda_stream_copy       = 0);

    HostIndexCache(const HostIndexCache&) = delete;
    HostIndexCache(HostIndexCache&&)      = delete;
    HostIndexCache& operator=(const HostIndexCache&) = delete;
    HostIndexCache& operator=(HostIndexCache&&) = delete;
    ~HostIndexCache()                           = default;

    /// \brief Generates indices on device and copies them to host memory
    ///
    /// If index already exists on host is may be reused.
    /// Indices from descriptors_of_indices_to_keep_on_device will be kept on device in addition to being to host. This is useful if the same indices
    /// are going to be requested by start_copying_indices_to_device() immediately after this call
    /// If skip_copy_to_host is true indices are going to be kept on device and not copied to host. In that case descriptors_of_indices_to_cache must
    /// be equal to descriptors_of_indices_to_keep_on_device and there must be only one call to start_copying_indices_to_device() with exactly these indices
    /// Calling this function invalidates any previously cached data for the same cache type
    ///
    /// \param cache_type
    /// \param descriptors_of_indices_to_cache
    /// \param descriptors_of_indices_to_keep_on_device
    /// \param skip_copy_to_host
    void generate_content(CacheType cache_type,
                          const std::vector<IndexDescriptor>& descriptors_of_indices_to_cache,
                          const std::vector<IndexDescriptor>& descriptors_of_indices_to_keep_on_device = {},
                          bool skip_copy_to_host                                                       = false);

    /// \brief Begins copying indices to device
    ///
    /// If index already exists on device it may be reused.
    /// This copy is done asynchronously. Function returns a DeviceIndexCache object which should be used to access the indices.
    /// Copy to device is finised by calling DeviceIndexCache::wait_for_data_to_be_ready().
    /// The user should make sure that every call to start_copying_indices_to_device() is accompanied by a call to DeviceIndexCache::wait_for_data_to_be_ready()
    ///
    /// \param cache_type
    /// \param descriptors_of_indices_to_cache
    /// \throw IndexNotFoundException if an index that is not cached by call to generate_content() is requested
    /// \return DeviceIndexCache object
    std::shared_ptr<DeviceIndexCache> start_copying_indices_to_device(CacheType cache_type,
                                                                      const std::vector<IndexDescriptor>& descriptors_of_indices_to_cache);

    /// \brief Registers DeviceIndexCache object
    /// \param cache_type
    /// \param index_cache
    void register_device_cache(CacheType cache_type,
                               DeviceIndexCache* index_cache);

    /// \brief Deregisters DeviceIndexCache object
    /// \param cache_type
    /// \param index_cache
    void deregister_device_cache(CacheType cache_type,
                                 DeviceIndexCache* index_cache);

private:
    using host_cache_t = std::unordered_map<IndexDescriptor,
                                            std::shared_ptr<const IndexHostCopyBase>,
                                            IndexDescriptorHash>;

    using device_cache_t = std::unordered_map<IndexDescriptor,
                                              std::shared_ptr<Index>,
                                              IndexDescriptorHash>;

    // Indices kept on host
    host_cache_t query_host_cache_;
    host_cache_t target_host_cache_;

    // Indices kept of device because of descriptors_of_indices_to_keep_on_device
    device_cache_t query_indices_kept_on_device_;
    device_cache_t target_indices_kept_on_device_;

    // Currently existing DeviceIndexCaches created by this HostIndexCache
    std::vector<DeviceIndexCache*> device_caches_query_;
    std::vector<DeviceIndexCache*> device_caches_target_;

    const bool same_query_and_target_;
    genomeworks::DefaultDeviceAllocator allocator_;
    std::shared_ptr<genomeworks::io::FastaParser> query_parser_;
    std::shared_ptr<genomeworks::io::FastaParser> target_parser_;
    const std::uint64_t kmer_size_;
    const std::uint64_t window_size_;
    const bool hash_representations_;
    const double filtering_parameter_;
    const cudaStream_t cuda_stream_generation_;
    const cudaStream_t cuda_stream_copy_;
};

/// IndexNotFoundException - Exception to be thrown if Index is reuqsted, but not found
class IndexNotFoundException : public std::exception
{
public:
    /// IndexLocation - Was the Index requested from host or device cache
    enum class IndexLocation
    {
        host_cache,
        device_cache
    };

    /// \brief constructor
    /// \param index_descriptor
    /// \param index_type was Index equested from host or device cache
    IndexNotFoundException(CacheType cache_type,
                           IndexLocation index_location,
                           IndexDescriptor index_descriptor);

    /// \brief Returns the error message of the exception
    virtual const char* what() const noexcept;

private:
    const std::string message_;
};

/// DeviceCacheNotReadyException - Exception ot be thrown when an index is requested before it has been copied completely
class DeviceCacheNotReadyException : public std::exception
{
public:
    /// \brief constructor
    /// \param cache_type
    /// \param index_descriptor
    DeviceCacheNotReadyException(CacheType cache_type,
                                 IndexDescriptor index_descriptor);

    /// \brief Returns the error message of the exception
    virtual const char* what() const noexcept;

private:
    const std::string message_;
};

} // namespace cudamapper

} // namespace genomeworks

} // namespace claraparabricks
