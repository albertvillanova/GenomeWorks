

#pragma once

#include "aligner_global.hpp"

namespace claraparabricks
{

namespace genomeworks
{

namespace cudaaligner
{

class AlignerGlobalMyers : public AlignerGlobal
{
public:
    AlignerGlobalMyers(int32_t max_query_length, int32_t max_target_length, int32_t max_alignments, DefaultDeviceAllocator allocator, cudaStream_t stream, int32_t device_id);
    virtual ~AlignerGlobalMyers();

private:
    struct Workspace;

    virtual void run_alignment(int8_t* results_d, int32_t* result_lengths_d, int32_t max_result_length,
                               const char* sequences_d, int32_t* sequence_lengths_d, int32_t* sequence_lengths_h, int32_t max_sequence_length,
                               int32_t num_alignments, cudaStream_t stream) override;

    std::unique_ptr<Workspace> workspace_;
};

} // namespace cudaaligner

} // namespace genomeworks

} // namespace claraparabricks
