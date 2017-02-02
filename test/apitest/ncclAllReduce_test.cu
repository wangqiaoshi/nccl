#include "ncclCommon_test.cuh"
template <typename DT>
class ncclAllReduce_test : public ncclCommon_test<DT> {};
TYPED_TEST_CASE(ncclAllReduce_test, testDataTypes);
// typical usage.
TYPED_TEST(ncclAllReduce_test, basic) {
    for (ncclRedOp_t op : this->RedOps) {
        for (int i = 0; i < this->nVis; ++i) {
            ASSERT_EQ(cudaSuccess, cudaSetDevice(i)) << "op: " << op << ", "
                                                     << "i" << i << ", "
                                                     << std::endl;
            ASSERT_EQ(ncclSuccess,
                      ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i],
                                    std::min(this->N, 1024 * 1024),
                                    this->DataType(), op, this->comms[i],
                                    this->streams[i]))
                << "op: " << op << ", "
                << "i" << i << ", " << std::endl;
        }
    }
};
TYPED_TEST(ncclAllReduce_test, host_mem) {
    for (ncclRedOp_t op : this->RedOps) {
        for (int i = 0; i < this->nVis; ++i) {
            ASSERT_EQ(cudaSuccess, cudaSetDevice(i)) << "op: " << op << ", "
                                                     << "i" << i << ", "
                                                     << std::endl;
            ASSERT_EQ(
                ncclInvalidDevicePointer,
                ncclAllReduce(this->sendbuffs_host[i], this->recvbuffs_host[i],
                              std::min(this->N, 1024 * 1024), this->DataType(),
                              op, this->comms[i], this->streams[i]))
                << "op: " << op << ", "
                << "i" << i << ", " << std::endl;
        }
    }
};
TYPED_TEST(ncclAllReduce_test, DISABLED_pinned_mem) {
    for (ncclRedOp_t op : this->RedOps) {
        for (int i = 0; i < this->nVis; ++i) {
            ASSERT_EQ(cudaSuccess, cudaSetDevice(i)) << "op: " << op << ", "
                                                     << "i" << i << ", "
                                                     << std::endl;
            ASSERT_EQ(ncclSuccess,
                      ncclAllReduce(
                          this->sendbuffs_pinned[i], this->recvbuffs_pinned[i],
                          std::min(this->N, 1024 * 1024), this->DataType(), op,
                          this->comms[i], this->streams[i]))
                << "op: " << op << ", "
                << "i" << i << ", " << std::endl;
        }
    }
};
// sendbuff
TYPED_TEST(ncclAllReduce_test, sendbuf_null) {
    int i = 0;
    EXPECT_EQ(ncclInvalidDevicePointer,
              ncclAllReduce(NULL, this->recvbuffs[i],
                            std::min(this->N, 1024 * 1024), this->DataType(),
                            this->RedOps[0], this->comms[i], this->streams[i]));
};
// recvbuff
TYPED_TEST(ncclAllReduce_test, recvbuf_null) {
    int i = 0;
    EXPECT_EQ(ncclInvalidDevicePointer,
              ncclAllReduce(this->sendbuffs[i], NULL,
                            std::min(this->N, 1024 * 1024), this->DataType(),
                            this->RedOps[0], this->comms[i], this->streams[i]));
};
// sendbuff and recvbuff not on the same device
TYPED_TEST(ncclAllReduce_test, sendbuff_recvbuff_diff_device) {
    int i = 0, j = 1;
    ASSERT_EQ(ncclInvalidDevicePointer,
              ncclAllReduce(this->sendbuffs[i], this->recvbuffs[j],
                            std::min(this->N, 1024 * 1024), this->DataType(),
                            this->RedOps[0], this->comms[i], this->streams[i]));
};
// N
TYPED_TEST(ncclAllReduce_test, N_zero) {
    for (ncclRedOp_t op : this->RedOps) {
        for (int i = 0; i < this->nVis; ++i) {
            ASSERT_EQ(cudaSuccess, cudaSetDevice(i)) << "op: " << op << ", "
                                                     << "i" << i << ", "
                                                     << std::endl;
            ASSERT_EQ(ncclSuccess,
                      ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i], 0,
                                    this->DataType(), this->RedOps[0],
                                    this->comms[i], this->streams[i]))
                << "op: " << op << ", "
                << "i" << i << ", " << std::endl;
        }
    }
};
TYPED_TEST(ncclAllReduce_test, N_minus1) {
    int i = 0;
    ASSERT_EQ(ncclInvalidArgument,
              ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i], -1,
                            this->DataType(), this->RedOps[0], this->comms[i],
                            this->streams[i]));
};
// data type
TYPED_TEST(ncclAllReduce_test, DataType_wrong) {
    int i = 0;
    ASSERT_EQ(ncclInvalidType,
              ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i],
                            std::min(this->N, 1024 * 1024), nccl_NUM_TYPES,
                            this->RedOps[0], this->comms[i], this->streams[i]));
};
// op
TYPED_TEST(ncclAllReduce_test, op_wrong) {
    int i = 0;
    ASSERT_EQ(ncclInvalidOperation,
              ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i],
                            std::min(this->N, 1024 * 1024), this->DataType(),
                            nccl_NUM_OPS, this->comms[i], this->streams[i]));
};
// comm
TYPED_TEST(ncclAllReduce_test, comm_null) {
    int i = 0;
    ASSERT_EQ(ncclInvalidArgument,
              ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i],
                            std::min(this->N, 1024 * 1024), this->DataType(),
                            this->RedOps[0], NULL, this->streams[i]));
};
TYPED_TEST(ncclAllReduce_test, comm_wrong) {
    int i = 0, j = 1;
    ASSERT_EQ(ncclInvalidDevicePointer,
              ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i],
                            std::min(this->N, 1024 * 1024), this->DataType(),
                            this->RedOps[0], this->comms[j], this->streams[i]));
};
// STREAM can be NULL.
// stream on a diff device
TYPED_TEST(ncclAllReduce_test, DISABLED_stream_wrong) {
    int i = 0, j = 1;
    ASSERT_EQ(ncclInvalidDevicePointer,
              ncclAllReduce(this->sendbuffs[i], this->recvbuffs[i],
                            std::min(this->N, 1024 * 1024), this->DataType(),
                            this->RedOps[0], this->comms[i], this->streams[j]));
};
// EOF