/* XMRig
 * Copyright 2010      Jeff Garzik <jgarzik@pobox.com>
 * Copyright 2012-2014 pooler      <pooler@litecoinpool.org>
 * Copyright 2014      Lucas Jones <https://github.com/lucasjones>
 * Copyright 2014-2016 Wolf9466    <https://github.com/OhGodAPet>
 * Copyright 2016      Jay D Dee   <jayddee246@gmail.com>
 * Copyright 2017-2018 XMR-Stak    <https://github.com/fireice-uk>, <https://github.com/psychocrypt>
 * Copyright 2018-2020 SChernykh   <https://github.com/SChernykh>
 * Copyright 2016-2020 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with this program. If not, see <http://www.gnu.org/licenses/>.
 */


#include <cuda.h>
#include <cuda_runtime.h>
#include <cstdint>

#include "cryptonight.h"
#include "cuda_device.hpp"
#include "KawPow_dag.h"
#include "CudaKawPow_gen.h"


static inline uint32_t clz(uint32_t a)
{
#ifdef _MSC_VER
    unsigned long index;
    _BitScanReverse(&index, a);
    return 31 - index;
#else
    return __builtin_clz(a);
#endif
}


static void calculate_fast_mod_data(uint32_t divisor, uint32_t& reciprocal, uint32_t& increment, uint32_t& shift)
{
    if ((divisor & (divisor - 1)) == 0) {
        reciprocal = 1;
        increment = 0;
        shift = 31U - clz(divisor);
    }
    else {
        shift = 63U - clz(divisor);
        const uint64_t N = 1ULL << shift;
        const uint64_t q = N / divisor;
        const uint64_t r = N - q * divisor;
        if (r * 2 < divisor)
        {
            reciprocal = static_cast<uint32_t>(q);
            increment = 1;
        }
        else
        {
            reciprocal = static_cast<uint32_t>(q + 1);
            increment = 0;
        }
    }
}


void kawpow_prepare(nvid_ctx *ctx, const void* cache, size_t cache_size, size_t dag_size, uint32_t height, const uint64_t* dag_sizes)
{
    constexpr size_t MEM_ALIGN = 4 * 1024 * 1024;

    if (cache_size != ctx->kawpow_cache_size) {
        ctx->kawpow_cache_size = cache_size;

        if (cache_size > ctx->kawpow_cache_capacity) {
            CUDA_CHECK(ctx->device_id, cudaFree(ctx->kawpow_cache));

            ctx->kawpow_cache_capacity = ((cache_size + MEM_ALIGN - 1) / MEM_ALIGN) * MEM_ALIGN;
            CUDA_CHECK(ctx->device_id, cudaMalloc(&ctx->kawpow_cache, ctx->kawpow_cache_capacity));
        }

        CUDA_CHECK(ctx->device_id, cudaMemcpy((uint8_t*)(ctx->kawpow_cache), cache, cache_size, cudaMemcpyHostToDevice));
    }

    if (dag_size != ctx->kawpow_dag_size) {
        ctx->kawpow_dag_size = dag_size;

        if (dag_size > ctx->kawpow_dag_capacity) {
            CUDA_CHECK(ctx->device_id, cudaFree(ctx->kawpow_dag));

            ctx->kawpow_dag_capacity = ((dag_size + MEM_ALIGN - 1) / MEM_ALIGN) * MEM_ALIGN;
            CUDA_CHECK(ctx->device_id, cudaMalloc(&ctx->kawpow_dag, ctx->kawpow_dag_capacity));
        }

        constexpr int blocks = 8192;
        constexpr int threads = 32;

        const size_t dag_items = dag_size / sizeof(hash64_t);

        uint4 light_words;
        light_words.w = ctx->kawpow_cache_size / sizeof(hash64_t);
        calculate_fast_mod_data(light_words.w, light_words.x, light_words.y, light_words.z);

        for (size_t i = 0; i < dag_items; i += blocks * threads) {
            CUDA_CHECK_KERNEL(ctx->device_id, ethash_calculate_dag_item<<<blocks, threads>>>(
                i,
                (hash64_t*) ctx->kawpow_dag,
                ctx->kawpow_dag_size,
                (hash64_t*) ctx->kawpow_cache,
                light_words
            ));
            CUDA_CHECK(ctx->device_id, cudaDeviceSynchronize());
        }
    }

    constexpr uint32_t PERIOD_LENGTH = 3;
    const uint32_t period = height / PERIOD_LENGTH;

    if (ctx->kawpow_period != period) {
        if (ctx->kawpow_module) {
            cuModuleUnload(ctx->kawpow_module);
        }

        std::vector<char> ptx;
        std::string lowered_name;
        KawPow_get_program(ptx, lowered_name, period, ctx->device_arch[0], ctx->device_arch[1], dag_sizes);

        CU_CHECK(ctx->device_id, cuModuleLoadDataEx(&ctx->kawpow_module, ptx.data(), 0, 0, 0));
        CU_CHECK(ctx->device_id, cuModuleGetFunction(&ctx->kawpow_kernel, ctx->kawpow_module, lowered_name.c_str()));

        ctx->kawpow_period = period;

        KawPow_get_program(ptx, lowered_name, period + 1, ctx->device_arch[0], ctx->device_arch[1], dag_sizes, true);
    }

    if (!ctx->kawpow_stop) {
        CUDA_CHECK(ctx->device_id, cudaMalloc(&ctx->kawpow_stop, sizeof(uint32_t) * 2));
    }
}


void kawpow_stop_hash(nvid_ctx *ctx)
{
    // TODO: this is called from the main thread which doesn't have a valid CUDA context, so nothing works here
}


namespace KawPow_Raven {

void hash(nvid_ctx *ctx, uint8_t* job_blob, uint64_t target, uint32_t *rescount, uint32_t *resnonce, uint32_t *skipped_hashes)
{
    dim3 grid(ctx->device_blocks);
    dim3 block(ctx->device_threads);

    uint32_t hack_false = 0;
    void* args[] = { &ctx->kawpow_dag, &ctx->d_input, &target, &hack_false, &ctx->d_result_nonce, &ctx->kawpow_stop };

    CUDA_CHECK(ctx->device_id, cudaMemcpy(ctx->d_input, job_blob, 40, cudaMemcpyHostToDevice));
    CUDA_CHECK(ctx->device_id, cudaMemset(ctx->d_result_nonce, 0, sizeof(uint32_t)));
    CUDA_CHECK(ctx->device_id, cudaMemset(ctx->kawpow_stop, 0, sizeof(uint32_t) * 2));

    CU_CHECK(ctx->device_id, cuLaunchKernel(
        ctx->kawpow_kernel,
        grid.x, grid.y, grid.z,
        block.x, block.y, block.z,
        0, nullptr, args, 0
    ));
    CU_CHECK(ctx->device_id, cuCtxSynchronize());

    uint32_t stop[2];
    CUDA_CHECK(ctx->device_id, cudaMemcpy(stop, ctx->kawpow_stop, sizeof(stop), cudaMemcpyDeviceToHost));

    *skipped_hashes = stop[1];

    uint32_t results[16];
    CUDA_CHECK(ctx->device_id, cudaMemcpy(results, ctx->d_result_nonce, sizeof(results), cudaMemcpyDeviceToHost));

    if (results[0] > 15) {
        results[0] = 15;
    }

    *rescount = results[0];
    memcpy(resnonce, results + 1, results[0] * sizeof(uint32_t));
}

}
