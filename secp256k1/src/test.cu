// test.cu

/*******************************************************************************

    TEST -- hash functions test suite

*******************************************************************************/

#include "../include/cryptography.h"
#include "../include/definitions.h"
#include "../include/easylogging++.h"
#include "../include/mining.h"
#include "../include/prehash.h"
#include "../include/reduction.h"
#include <ctype.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cooperative_groups.h>
#include <curl/curl.h>
#include <inttypes.h>
#include <iostream>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

INITIALIZE_EASYLOGGINGPP

namespace ch = std::chrono;

////////////////////////////////////////////////////////////////////////////////
//  Test solutions correctness
////////////////////////////////////////////////////////////////////////////////
int TestSolutions(
    const info_t * info,
    const uint8_t * x,
    const uint8_t * w
)
{
    LOG(INFO) << "Solutions test started";
    LOG(INFO) << "Set keepPrehash = " << ((info->keepPrehash)? "true": "false");

    //========================================================================//
    //  Host memory allocation
    //========================================================================//
    // hash context
    // (212 + 4) bytes
    ctx_t ctx_h;

    //========================================================================//
    //  Device memory allocation
    //========================================================================//
    // boundary for puzzle
    // ~0 MiB
    uint32_t * bound_d;
    CUDA_CALL(cudaMalloc(&bound_d, NUM_SIZE_8 + DATA_SIZE_8));
    // data: pk || mes || w || padding || x || sk || ctx
    // (2 * PK_SIZE_8 + 2 + 3 * NUM_SIZE_8 + 212 + 4) bytes // ~0 MiB
    uint32_t * data_d = bound_d + NUM_SIZE_32;

    // precalculated hashes
    // N_LEN * NUM_SIZE_8 bytes // 2 GiB
    uint32_t * hashes_d;
    CUDA_CALL(cudaMalloc(&hashes_d, (uint32_t)N_LEN * NUM_SIZE_8));

    // WORKSPACE_SIZE_8 bytes
    // potential solutions of puzzle
    uint32_t * res_d;
    CUDA_CALL(cudaMalloc(&res_d, WORKSPACE_SIZE_8));
    // indices of unfinalized hashes
    uint32_t * indices_d = res_d + NONCES_PER_ITER * NUM_SIZE_32;

    uctx_t * uctxs_d = NULL;

    if (info->keepPrehash)
    {
        CUDA_CALL(cudaMalloc(&uctxs_d, (uint32_t)N_LEN * sizeof(uctx_t)));
    }

    //========================================================================//
    //  Data transfer form host to device
    //========================================================================//
    // copy boundary
    CUDA_CALL(cudaMemcpy(
        bound_d, info->bound, NUM_SIZE_8, cudaMemcpyHostToDevice
    ));

    // copy public key
    CUDA_CALL(cudaMemcpy(data_d, info->pk, PK_SIZE_8, cudaMemcpyHostToDevice));

    // copy message
    CUDA_CALL(cudaMemcpy(
        (uint8_t *)data_d + PK_SIZE_8, info->mes, NUM_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    // copy one time public key
    CUDA_CALL(cudaMemcpy(
        (uint8_t *)data_d + PK_SIZE_8 + NUM_SIZE_8, w, PK_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    // copy one time secret key
    CUDA_CALL(cudaMemcpy(
        data_d + COUPLED_PK_SIZE_32 + NUM_SIZE_32, x, NUM_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    // copy secret key
    CUDA_CALL(cudaMemcpy(
        data_d + COUPLED_PK_SIZE_32 + 2 * NUM_SIZE_32, info->sk, NUM_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    //========================================================================//
    //  Test solutions
    //========================================================================//
    uint64_t base = 0;

    if (info->keepPrehash)
    {
        UncompleteInitPrehash<<<1 + (N_LEN - 1) / BLOCK_DIM, BLOCK_DIM>>>(
            data_d, uctxs_d
        );
    }

    Prehash(info->keepPrehash, data_d, uctxs_d, hashes_d, res_d);
    CUDA_CALL(cudaDeviceSynchronize());

    // calculate unfinalized hash of message
    InitMining(&ctx_h, (uint32_t *)info->mes, NUM_SIZE_8);

    // copy context
    CUDA_CALL(cudaMemcpy(
        data_d + COUPLED_PK_SIZE_32 + 3 * NUM_SIZE_32, &ctx_h, sizeof(ctx_t),
        cudaMemcpyHostToDevice
    ));

    // calculate solution candidates
    BlockMining<<<1 + (THREADS_PER_ITER - 1) / BLOCK_DIM, BLOCK_DIM>>>(
        bound_d, data_d, base, hashes_d, res_d, indices_d
    );

    const uint32_t ref_indices[3] = { 0x3381BD, 0x376C26, 0x3D5B84 };

    const uint64_t ref_res[3 * NUM_SIZE_64] = {
        0xA41F6C4914B3BCD0, 0x71EEA8CF5356CF28, 0xADB7E97512C1B9AD,
        0x8081936D54481DD8, 0x661D4798E2309692, 0x7EAE28B576532950,
        0x3D2B0B32A1E52137, 0x2406A4B8304E264A, 0x1329C47EBABBB9A8,
        0x9D7AFFEA975A94CF, 0xABFBCFEA7171F4AA, 0x3BA19A1A3D28B102
    };

    uint64_t res_h[3 * NUM_SIZE_64];

    for (int i = 0; i < 3; ++i)
    {
        // copy results to host
        CUDA_CALL(cudaMemcpy(
            res_h, res_d + ref_indices[i] * NUM_SIZE_32, NUM_SIZE_8,
            cudaMemcpyDeviceToHost
        ));

        if (memcmp(res_h, ref_res + i * NUM_SIZE_64, NUM_SIZE_8))
        {
            LOG(ERROR) << "Solutions test failed";
            exit(EXIT_FAILURE);
        }
    }

    //========================================================================//
    //  Device memory deallocation
    //========================================================================//
    CUDA_CALL(cudaFree(bound_d));
    CUDA_CALL(cudaFree(hashes_d));
    CUDA_CALL(cudaFree(res_d));

    if (info->keepPrehash) { CUDA_CALL(cudaFree(uctxs_d)); }

    LOG(INFO) << "Solutions test passed\n";

    return EXIT_SUCCESS;
}

////////////////////////////////////////////////////////////////////////////////
//  Test performance
////////////////////////////////////////////////////////////////////////////////
int TestPerformance(
    const info_t * info,
    const uint8_t * x,
    const uint8_t * w
)
{
    LOG(INFO) << "Performance test started";

    //========================================================================//
    //  Host memory allocation
    //========================================================================//
    // hash context
    // (212 + 4) bytes
    ctx_t ctx_h;

    //========================================================================//
    //  Device memory allocation
    //========================================================================//
    // boundary for puzzle
    // ~0 MiB
    uint32_t * bound_d;
    CUDA_CALL(cudaMalloc(&bound_d, NUM_SIZE_8 + DATA_SIZE_8));
    // data: pk || mes || w || padding || x || sk || ctx
    // (2 * PK_SIZE_8 + 2 + 3 * NUM_SIZE_8 + 212 + 4) bytes // ~0 MiB
    uint32_t * data_d = bound_d + NUM_SIZE_32;

    // precalculated hashes
    // N_LEN * NUM_SIZE_8 bytes // 2 GiB
    uint32_t * hashes_d;
    CUDA_CALL(cudaMalloc(&hashes_d, (uint32_t)N_LEN * NUM_SIZE_8));

    // WORKSPACE_SIZE_8 bytes
    // potential solutions of puzzle
    uint32_t * res_d;
    CUDA_CALL(cudaMalloc(&res_d, WORKSPACE_SIZE_8));
    // indices of unfinalized hashes
    uint32_t * indices_d = res_d + NONCES_PER_ITER * NUM_SIZE_32;

    uctx_t * uctxs_d = NULL;

    if (info->keepPrehash)
    {
        CUDA_CALL(cudaMalloc(&uctxs_d, (uint32_t)N_LEN * sizeof(uctx_t)));
    }

    //========================================================================//
    //  Data transfer form host to device
    //========================================================================//
    // copy boundary
    CUDA_CALL(cudaMemcpy(
        bound_d, info->bound, NUM_SIZE_8, cudaMemcpyHostToDevice
    ));

    // copy public key
    CUDA_CALL(cudaMemcpy(data_d, info->pk, PK_SIZE_8, cudaMemcpyHostToDevice));

    // copy message
    CUDA_CALL(cudaMemcpy(
        (uint8_t *)data_d + PK_SIZE_8, info->mes, NUM_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    // copy one time public key
    CUDA_CALL(cudaMemcpy(
        (uint8_t *)data_d + PK_SIZE_8 + NUM_SIZE_8, w, PK_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    // copy one time secret key
    CUDA_CALL(cudaMemcpy(
        data_d + COUPLED_PK_SIZE_32 + NUM_SIZE_32, x, NUM_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    // copy secret key
    CUDA_CALL(cudaMemcpy(
        data_d + COUPLED_PK_SIZE_32 + 2 * NUM_SIZE_32, info->sk, NUM_SIZE_8,
        cudaMemcpyHostToDevice
    ));

    //========================================================================//
    //  Test solutions
    //========================================================================//
    uint64_t base = 0;

    ch::milliseconds ms = ch::milliseconds::zero(); 

    LOG(INFO) << "Set keepPrehash = false";

    ch::milliseconds start = ch::duration_cast<ch::milliseconds>(
        ch::system_clock::now().time_since_epoch()
    );

    Prehash(0, data_d, NULL, hashes_d, res_d);

    ms = ch::duration_cast<ch::milliseconds>(
        ch::system_clock::now().time_since_epoch()
    ) - start;

    LOG(INFO) << "Prehash time: " << ms.count() << " ms";

    if (info->keepPrehash)
    {
        LOG(INFO) << "Set keepPrehash = true";

        UncompleteInitPrehash<<<1 + (N_LEN - 1) / BLOCK_DIM, BLOCK_DIM>>>(
            data_d, uctxs_d
        );

        start = ch::duration_cast<ch::milliseconds>(
            ch::system_clock::now().time_since_epoch()
        );

        Prehash(1, data_d, uctxs_d, hashes_d, res_d);

        ms = ch::duration_cast<ch::milliseconds>(
            ch::system_clock::now().time_since_epoch()
        ) - start;

        LOG(INFO) << "Prehash time: " << ms.count() << " ms";
    }

    CUDA_CALL(cudaDeviceSynchronize());

    // calculate unfinalized hash of message
    InitMining(&ctx_h, (uint32_t *)info->mes, NUM_SIZE_8);

    // copy context
    CUDA_CALL(cudaMemcpy(
        data_d + COUPLED_PK_SIZE_32 + 3 * NUM_SIZE_32, &ctx_h, sizeof(ctx_t),
        cudaMemcpyHostToDevice
    ));

    LOG(INFO) << "BlockMining now for 1 minute";
    ms = ch::milliseconds::zero();

    uint32_t sum = 0;
    int iter = 0;

    start = ch::duration_cast<ch::milliseconds>(
        ch::system_clock::now().time_since_epoch()
    );

    for ( ; ms.count() < 60000; ++iter)
    {
        // calculate solution candidates
        BlockMining<<<1 + (THREADS_PER_ITER - 1) / BLOCK_DIM, BLOCK_DIM>>>(
            bound_d, data_d, base, hashes_d, res_d, indices_d
        );

        sum += FindSum(indices_d, indices_d + NONCES_PER_ITER, NONCES_PER_ITER);

        base += NONCES_PER_ITER;

        ms = ch::duration_cast<ch::milliseconds>(
            ch::system_clock::now().time_since_epoch()
        ) - start;
    }

    //========================================================================//
    //  Device memory deallocation
    //========================================================================//
    CUDA_CALL(cudaFree(bound_d));
    CUDA_CALL(cudaFree(hashes_d));
    CUDA_CALL(cudaFree(res_d));

    if (info->keepPrehash) { CUDA_CALL(cudaFree(uctxs_d)); }

    LOG(INFO) << "Found " << sum << " solutions";
    LOG(INFO) << "Hashrate: " << (double)NONCES_PER_ITER * iter
        / ((double)1000 * ms.count()) << " MH/s";
    LOG(INFO) << "Performance test completed\n";

    return EXIT_SUCCESS;
}

////////////////////////////////////////////////////////////////////////////////
//  Main
////////////////////////////////////////////////////////////////////////////////
int main(int argc, char ** argv)
{
    START_EASYLOGGINGPP(argc, argv);

    el::Loggers::reconfigureAllLoggers(
        el::ConfigurationType::Format, "%datetime %level [%thread] %msg"
    );

    el::Helpers::setThreadName("test thread");

    //========================================================================//
    //  Check requirements
    //========================================================================//
    int deviceCount;

    if (cudaGetDeviceCount(&deviceCount) != cudaSuccess)
    {
        LOG(ERROR) << "Error checking GPU";
        exit(EXIT_FAILURE);
    }

    size_t freeMem;
    size_t totalMem;

    CUDA_CALL(cudaMemGetInfo(&freeMem, &totalMem));
    
    if (freeMem < MIN_FREE_MEMORY)
    {
        LOG(ERROR) << "Not enough GPU memory for mining,"
            << " minimum 2.8 GiB needed";

        exit(EXIT_FAILURE);
    }
    
    //========================================================================//
    //  Set test info
    //========================================================================//
    info_t info;
    uint8_t x[NUM_SIZE_8];
    uint8_t w[PK_SIZE_8];
    char seed[256] = "Va'esse deireadh aep eigean, va'esse eigh faidh'ar";

    // generate secret key from seed
    GenerateSecKey(seed, 50, info.sk, info.skstr);
    // generate public key from secret key
    GeneratePublicKey(info.skstr, info.pkstr, info.pk);

    const char ref_pkstr[PK_SIZE_4 + 1]
        = "020C16DFC5E23C59357E89D44977038F0A7851CC9926B3AABB3FF9E7E6A57315AD";

    int test = !strncmp(ref_pkstr, info.pkstr, PK_SIZE_4);

    if (!test)
    {
        LOG(ERROR) << "OpenSSL: generated wrong public key";
        return EXIT_FAILURE;
    }

    ((uint64_t *)info.bound)[0] = 0xFFFFFFFFFFFFFFFF;
    ((uint64_t *)info.bound)[1] = 0xFFFFFFFFFFFFFFFF;
    ((uint64_t *)info.bound)[2] = 0xFFFFFFFFFFFFFFFF;
    ((uint64_t *)info.bound)[3] = 0x00000FFFFFFFFFFF;

    ((uint64_t *)info.mes)[0] = 1;
    ((uint64_t *)info.mes)[1] = 0;
    ((uint64_t *)info.mes)[2] = 0;
    ((uint64_t *)info.mes)[3] = 0;

    sprintf(seed, "%d", 0);

    // generate secret key from seed
    GenerateSecKey(seed, 1, x, info.skstr);
    // generate public key from secret key
    GeneratePublicKey(info.skstr, info.pkstr, w);

    //========================================================================//
    //  Run solutions correctness tests
    //========================================================================//
    if (NONCES_PER_ITER <= 0x3D5B84)
    {
        LOG(INFO) << "Need WORKSPACE value for at least 4021125,"
            << " skip solutions tests\n";
    }
    else
    {
        info.keepPrehash = 0;
        TestSolutions(&info, x, w);

        if (freeMem < MIN_FREE_MEMORY_PREHASH)
        {
            LOG(INFO) << "Not enough GPU memory for keeping prehashes, "
                << "skip test\n";
        }
        else
        {
            info.keepPrehash = 1;
            TestSolutions(&info, x, w);
        }
    }

    //========================================================================//
    //  Run performance tests
    //========================================================================//
    info.keepPrehash = (freeMem >= MIN_FREE_MEMORY_PREHASH)? 1: 0;
    TestPerformance(&info, x, w);

    LOG(INFO) << "Test suite executable is now terminated";

    return EXIT_SUCCESS;
}

// test.cu
