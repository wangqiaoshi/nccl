class ncclCommInitAll_test : public ::testing::Test {
  protected:
    ncclComm_t* comms = NULL;
    int* devList = NULL;
    int nVis = 0;
    virtual void SetUp() {
        ASSERT_EQ(cudaSuccess, cudaGetDeviceCount(&nVis));
        comms = (ncclComm_t*)calloc(nVis, sizeof(ncclComm_t));
        devList = (int*)calloc(nVis, sizeof(int));
        for (int i = 0; i < nVis; i++) {
            devList[i] = i;
        }
    };
    virtual void TearDown() {
        if (NULL != devList) {
            free(devList);
            devList = NULL;
        }
        if (NULL != comms) {
            for (int i = 0; i < nVis; ++i) {
                ASSERT_EQ(ncclSuccess, ncclCommDestroy(comms[i]));
                comms[i] = NULL;
            }
            free(comms);
            comms = NULL;
        }
    };
};
TEST_F(ncclCommInitAll_test, basic) {
    ASSERT_EQ(ncclSuccess, ncclCommInitAll(comms, nVis, devList));
};
// 1.
TEST_F(ncclCommInitAll_test, comms_null) {
    ASSERT_EQ(ncclInvalidArgument, ncclCommInitAll(NULL, nVis, devList));
};
// 2.
TEST_F(ncclCommInitAll_test, ndev_0) {
    ASSERT_EQ(ncclInvalidArgument, ncclCommInitAll(comms, 0, devList));
};
TEST_F(ncclCommInitAll_test, ndev_negative) {
    ASSERT_EQ(ncclInvalidArgument, ncclCommInitAll(comms, -1, devList));
};
// TODO: fix this
TEST_F(ncclCommInitAll_test, DISABLED_ndev_toomany) {
    int ndev = 100;
    ncclComm_t* pcomms = (ncclComm_t*)calloc(ndev, sizeof(ncclComm_t));
    EXPECT_EQ(ncclInvalidArgument, ncclCommInitAll(pcomms, ndev, NULL));
    if (NULL != pcomms) {
        for (int i = 0; i < ndev; ++i) {
            ncclCommDestroy(pcomms[i]);
            pcomms[i] = NULL;
        }
        free(pcomms);
        pcomms = NULL;
    }
};
#if 1 // useless?
TEST_F(ncclCommInitAll_test, ndev_toomany_and_devList_allZero) {
    int ndev = 100;
    comms = (ncclComm_t*)calloc(ndev, sizeof(ncclComm_t));
    devList = (int*)calloc(ndev, sizeof(int));
    ASSERT_EQ(ncclInvalidArgument,
              ncclCommInitAll(comms, ndev, devList));
};
#endif
// 3.
TEST_F(ncclCommInitAll_test, devList_null) {
    ASSERT_EQ(ncclSuccess, ncclCommInitAll(comms, nVis, NULL));
};
TEST_F(ncclCommInitAll_test, devList_nonexist) {
    int* badDevList = (int*)calloc(nVis, sizeof(int));
    for (int i = 0; i < nVis; ++i) {
        badDevList[i] = 1000 + i;
    }
    ASSERT_EQ(ncclUnhandledCudaError, ncclCommInitAll(comms, nVis, badDevList));
    free(badDevList);
};
// EOF
