/*************************************************************************
 * Copyright (c) 2016, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 ************************************************************************/

#include <stdio.h>

// Based on //sw/gpgpu/MachineLearning/cudnn/test/testUtil.cpp

#define POLYNOMIAL 0x04c11db7L      // Standard CRC-32 ppolynomial
static unsigned int crc_table[256]; // Table of 8-bit remainders
static int tableLoaded = 0;

static void crcInit(void) {
  int i, j;
  unsigned int crc_accum;

  for (i=0;  i<256;  i++) {
    crc_accum = ( i << 24 );
    for ( j = 0;  j < 8;  j++ ) {
      if ( crc_accum & 0x80000000L )
        crc_accum = (crc_accum << 1) ^ POLYNOMIAL;
      else
        crc_accum = (crc_accum << 1);
    }
    crc_table[i] = crc_accum;
  }
}

unsigned calcCRCHost(unsigned char *data_blk_ptr, size_t data_blk_size) {
  if (tableLoaded == 0) {
    crcInit();
    tableLoaded = 1;
  }

  unsigned int crc_accum = 0x11223344; // Initial CRC value used in cuDNN
  int i;
  for (size_t j=0; j<data_blk_size; j++) {
    i = ((int) (crc_accum >> 24) ^ *data_blk_ptr++) & 0xFF;
    crc_accum = (crc_accum << 8) ^ crc_table[i];
  }
  crc_accum = ~crc_accum;
  return crc_accum;
}


static __global__ void CRCKernel(unsigned char* data, int bytes, int rank) {
  __shared__ unsigned crc_table[256];
  __shared__ unsigned char buffer[256];

  // Build table of 8-bit remainders
  int crc_accum = threadIdx.x << 24;
  for (int j=0; j<8; ++j) {
    const int mask = (crc_accum & 0x80000000) ? POLYNOMIAL : 0;
    crc_accum = (crc_accum << 1) ^ mask;
  }
  crc_table[threadIdx.x] = crc_accum;

  unsigned int crc_val = 0x11223344; // Initial CRC value used in cuDNN
  for(int i=threadIdx.x; i<bytes; i+=256) {
    buffer[threadIdx.x] = data[i];
    __syncthreads();

    if (threadIdx.x == 0) {
      const int remaining = bytes - i;
      const int n = (remaining > 256) ? 256 : remaining;
      for(int j=0; j<n; ++j) {
        int t = ((int)(crc_val >> 24) ^ buffer[j]) & 0xFF;
        crc_val = (crc_val << 8) ^ crc_table[t];
      }
    }
    __syncthreads();
  }

  if (threadIdx.x == 0)
    printf("NCCL Rank %d CRC 0x%.8x\n", rank, ~crc_val);
}

void printCRCDev(unsigned char* data,
                 int bytes,
                 int rank,
                 cudaStream_t stream)
{
  CRCKernel<<<1, 256, 0, stream>>>(data, bytes, rank);
}
