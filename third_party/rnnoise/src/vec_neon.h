/* Copyright (c) 2018 David Rowe
                 2018 Mozilla
                 2008-2011 Octasic Inc.
                 2012-2017 Jean-Marc Valin */
/*
   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

   - Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
/* NEON support for ARM machines */

#ifndef VEC_NEON_H
#define VEC_NEON_H

#include <arm_neon.h>
#include "opus_types.h"
#include "common.h"

#if defined(__arm__) && !defined(__aarch64__) && (__ARM_ARCH < 8 || !defined(__clang__))
/* Emulate vcvtnq_s32_f32() for ARMv7 Neon. */
static OPUS_INLINE int32x4_t vcvtnq_s32_f32(float32x4_t x) {
  return vrshrq_n_s32(vcvtq_n_s32_f32(x, 8), 8);
}

static OPUS_INLINE int16x8_t vpaddq_s16(int16x8_t a, int16x8_t b) {
  return vcombine_s16(vpadd_s16(vget_low_s16(a), vget_high_s16(a)), vpadd_s16(vget_low_s16(b), vget_high_s16(b)));
}

static OPUS_INLINE int16x8_t vmull_high_s8(int8x16_t a, int8x16_t b) {
  return vmull_s8(vget_high_s8(a), vget_high_s8(b));
}
#endif

#ifdef __ARM_FEATURE_FMA
/* If we can, force the compiler to use an FMA instruction rather than break
   vmlaq_f32() into fmul/fadd. */
#define vmlaq_f32(a,b,c) vfmaq_f32(a,b,c)
#endif

#ifndef LPCNET_TEST
static inline float32x4_t exp4_approx(float32x4_t x) {
  int32x4_t i;
  float32x4_t xf;

  x = vmaxq_f32(vminq_f32(x, vdupq_n_f32(88.f)), vdupq_n_f32(-88.f));

  /* express exp(x) as exp2(x/log(2)), add 127 for the exponent later */
  x = vmlaq_f32(vdupq_n_f32(127.f), x, vdupq_n_f32(1.44269504f));

  /* split into integer and fractional parts */
  i = vcvtq_s32_f32(x);
  xf = vcvtq_f32_s32(i);
  x = vsubq_f32(x, xf);

  float32x4_t K0 = vdupq_n_f32(0.99992522f);
  float32x4_t K1 = vdupq_n_f32(0.69583354f);
  float32x4_t K2 = vdupq_n_f32(0.22606716f);
  float32x4_t K3 = vdupq_n_f32(0.078024523f);
  float32x4_t Y = vmlaq_f32(K0, x, vmlaq_f32(K1, x, vmlaq_f32(K2, K3, x)));

  /* compute 2^i */
  float32x4_t exponent = vreinterpretq_f32_s32(vshlq_n_s32(i, 23));

  Y = vmulq_f32(Y, exponent);
  return Y;
}

static inline float32x4_t tanh4_approx(float32x4_t X)
{
  const float32x4_t N0 = vdupq_n_f32(952.52801514f);
  const float32x4_t N1 = vdupq_n_f32(96.39235687f);
  const float32x4_t N2 = vdupq_n_f32(0.60863042f);
  const float32x4_t D0 = vdupq_n_f32(952.72399902f);
  const float32x4_t D1 = vdupq_n_f32(413.36801147f);
  const float32x4_t D2 = vdupq_n_f32(11.88600922f);
  const float32x4_t max_out = vdupq_n_f32(1.f);
  const float32x4_t min_out = vdupq_n_f32(-1.f);
  float32x4_t X2, num, den;
  X2 = vmulq_f32(X, X);
  num = vmlaq_f32(N0, X2, vmlaq_f32(N1, N2, X2));
  den = vmlaq_f32(D0, X2, vmlaq_f32(D1, D2, X2));
  num = vmulq_f32(num, X);
  den = vrecpeq_f32(den);
  num = vmulq_f32(num, den);
  return vmaxq_f32(min_out, vminq_f32(max_out, num));
}

static inline float32x4_t sigmoid4_approx(float32x4_t X)
{
  const float32x4_t N0 = vdupq_n_f32(238.13200378f);
  const float32x4_t N1 = vdupq_n_f32(6.02452230f);
  const float32x4_t N2 = vdupq_n_f32(0.00950985f);
  const float32x4_t D0 = vdupq_n_f32(952.72399902f);
  const float32x4_t D1 = vdupq_n_f32(103.34200287f);
  const float32x4_t D2 = vdupq_n_f32(0.74287558f);
  const float32x4_t half = vdupq_n_f32(0.5f);
  const float32x4_t max_out = vdupq_n_f32(1.f);
  const float32x4_t min_out = vdupq_n_f32(0.f);
  float32x4_t X2, num, den;
  X2 = vmulq_f32(X, X);
  num = vmlaq_f32(N0, X2, vmlaq_f32(N1, N2, X2));
  den = vmlaq_f32(D0, X2, vmlaq_f32(D1, D2, X2));
  num = vmulq_f32(num, X);
  den = vrecpeq_f32(den);
  num = vmlaq_f32(half, num, den);
  return vmaxq_f32(min_out, vminq_f32(max_out, num));
}

static inline float lpcnet_exp(float x)
{
   float out[4];
   float32x4_t X, Y;
   X = vdupq_n_f32(x);
   Y = exp4_approx(X);
   vst1q_f32(out, Y);
   return out[0];
}

static inline float tanh_approx(float x)
{
   float out[4];
   float32x4_t X, Y;
   X = vdupq_n_f32(x);
   Y = tanh4_approx(X);
   vst1q_f32(out, Y);
   return out[0];
}

static inline float sigmoid_approx(float x)
{
   float out[4];
   float32x4_t X, Y;
   X = vdupq_n_f32(x);
   Y = sigmoid4_approx(X);
   vst1q_f32(out, Y);
   return out[0];
}

static inline void softmax(float *y, const float *x, int N)
{
    int i;
    for (i=0;i<N-3;i+=4)
    {
        float32x4_t X, Y;
        X = vld1q_f32(&x[i]);
        Y = exp4_approx(X);
        vst1q_f32(&y[i], Y);
    }
    for (;i<N;i++)
        y[i] = lpcnet_exp(x[i]);
}

static inline void vec_tanh(float *y, const float *x, int N)
{
    int i;
    for (i=0;i<N-3;i+=4)
    {
        float32x4_t X, Y;
        X = vld1q_f32(&x[i]);
        Y = tanh4_approx(X);
        vst1q_f32(&y[i], Y);
    }
    for (;i<N;i++)
    {
        float ex2;
        ex2 = lpcnet_exp(2*x[i]);
        y[i] = (ex2-1)/(ex2+1);
    }
}

static inline void vec_sigmoid(float *y, const float *x, int N)
{
    int i;
    for (i=0;i<N-3;i+=4)
    {
        float32x4_t X, Y;
        X = vld1q_f32(&x[i]);
        Y = sigmoid4_approx(X);
        vst1q_f32(&y[i], Y);
    }
    for (;i<N;i++)
    {
        float ex;
        ex = lpcnet_exp(x[i]);
        y[i] = (ex)/(ex+1);
    }
}
#endif

static inline void sgemv16x1(float *out, const float *weights, int rows, int cols, int col_stride, const float *x)
{
    int i, j;
    for (i=0;i<rows;i+=16)
    {
	float * restrict y = &out[i];

	/* keep y[0..15] in registers for duration of inner loop */

	float32x4_t y0_3 = vdupq_n_f32(0);
	float32x4_t y4_7 = vdupq_n_f32(0);
	float32x4_t y8_11 = vdupq_n_f32(0);
	float32x4_t y12_15 = vdupq_n_f32(0);

	for (j=0;j<cols;j++)
	{
	    const float * restrict w;
	    float32x4_t wvec0_3, wvec4_7, wvec8_11, wvec12_15;
	    float32x4_t xj;

	    w = &weights[j*col_stride + i];
	    wvec0_3 = vld1q_f32(&w[0]);
	    wvec4_7 = vld1q_f32(&w[4]);
	    wvec8_11 = vld1q_f32(&w[8]);
	    wvec12_15 = vld1q_f32(&w[12]);

	    xj = vld1q_dup_f32(&x[j]);

	    y0_3 = vmlaq_f32(y0_3, wvec0_3, xj);
	    y4_7 = vmlaq_f32(y4_7, wvec4_7, xj);
	    y8_11 = vmlaq_f32(y8_11, wvec8_11, xj);
	    y12_15 = vmlaq_f32(y12_15, wvec12_15, xj);
	}

	/* save y[0..15] back to memory */

	vst1q_f32(&y[0], y0_3);
	vst1q_f32(&y[4], y4_7);
	vst1q_f32(&y[8], y8_11);
	vst1q_f32(&y[12], y12_15);

    }
}

static inline void sgemv8x1(float *out, const float *weights, int rows, int cols, int col_stride, const float *x)
{
    int i, j;
    for (i=0;i<rows;i+=8)
    {
    float * restrict y = &out[i];

    /* keep y[0..15] in registers for duration of inner loop */

    float32x4_t y0_3 = vdupq_n_f32(0);
    float32x4_t y4_7 = vdupq_n_f32(0);

    for (j=0;j<cols;j++)
    {
        const float * restrict w;
        float32x4_t wvec0_3, wvec4_7;
        float32x4_t xj;

        w = &weights[j*col_stride + i];
        wvec0_3 = vld1q_f32(&w[0]);
        wvec4_7 = vld1q_f32(&w[4]);

        xj = vld1q_dup_f32(&x[j]);

        y0_3 = vmlaq_f32(y0_3, wvec0_3, xj);
        y4_7 = vmlaq_f32(y4_7, wvec4_7, xj);
    }

    /* save y[0..15] back to memory */

    vst1q_f32(&y[0], y0_3);
    vst1q_f32(&y[4], y4_7);
    }
}

static inline void sgemv(float *out, const float *weights, int rows, int cols, int col_stride, const float *x)
{
   if ((rows&0xf) == 0) sgemv16x1(out, weights, rows, cols, col_stride, x);
   else if ((rows&0x7) == 0) sgemv8x1(out, weights, rows, cols, col_stride, x);
   else {
      int i, j;
      for (i=0;i<rows;i++)
      {
         out[i] = 0;
         for (j=0;j<cols;j++) out[i] += weights[j*col_stride + i]*x[j];
      }
   }
}

#define HAVE_SGEMV_PAIR 1
static inline void sgemv_pair(float * restrict out0, float * restrict out1,
      const float * restrict weights, int rows, int cols, int col_stride,
      const float * restrict x0, const float * restrict x1)
{
   int i, j;
   if ((rows&0x7) != 0) {
      sgemv(out0, weights, rows, cols, col_stride, x0);
      sgemv(out1, weights, rows, cols, col_stride, x1);
      return;
   }
   if ((rows&0xf) == 0) {
      for (i=0;i<rows;i+=16)
      {
         float32x4_t y0_0_3 = vdupq_n_f32(0);
         float32x4_t y0_4_7 = vdupq_n_f32(0);
         float32x4_t y0_8_11 = vdupq_n_f32(0);
         float32x4_t y0_12_15 = vdupq_n_f32(0);
         float32x4_t y1_0_3 = vdupq_n_f32(0);
         float32x4_t y1_4_7 = vdupq_n_f32(0);
         float32x4_t y1_8_11 = vdupq_n_f32(0);
         float32x4_t y1_12_15 = vdupq_n_f32(0);
         for (j=0;j<cols;j++)
         {
            const float *w = &weights[j*col_stride + i];
            float32x4_t w0_3 = vld1q_f32(&w[0]);
            float32x4_t w4_7 = vld1q_f32(&w[4]);
            float32x4_t w8_11 = vld1q_f32(&w[8]);
            float32x4_t w12_15 = vld1q_f32(&w[12]);
            float32x4_t input0 = vld1q_dup_f32(&x0[j]);
            float32x4_t input1 = vld1q_dup_f32(&x1[j]);
            y0_0_3 = vmlaq_f32(y0_0_3, w0_3, input0);
            y0_4_7 = vmlaq_f32(y0_4_7, w4_7, input0);
            y0_8_11 = vmlaq_f32(y0_8_11, w8_11, input0);
            y0_12_15 = vmlaq_f32(y0_12_15, w12_15, input0);
            y1_0_3 = vmlaq_f32(y1_0_3, w0_3, input1);
            y1_4_7 = vmlaq_f32(y1_4_7, w4_7, input1);
            y1_8_11 = vmlaq_f32(y1_8_11, w8_11, input1);
            y1_12_15 = vmlaq_f32(y1_12_15, w12_15, input1);
         }
         vst1q_f32(&out0[i], y0_0_3);
         vst1q_f32(&out0[i+4], y0_4_7);
         vst1q_f32(&out0[i+8], y0_8_11);
         vst1q_f32(&out0[i+12], y0_12_15);
         vst1q_f32(&out1[i], y1_0_3);
         vst1q_f32(&out1[i+4], y1_4_7);
         vst1q_f32(&out1[i+8], y1_8_11);
         vst1q_f32(&out1[i+12], y1_12_15);
      }
      return;
   }
   for (i=0;i<rows;i+=8)
   {
      float32x4_t y0_0_3 = vdupq_n_f32(0);
      float32x4_t y0_4_7 = vdupq_n_f32(0);
      float32x4_t y1_0_3 = vdupq_n_f32(0);
      float32x4_t y1_4_7 = vdupq_n_f32(0);
      for (j=0;j<cols;j++)
      {
         const float *w = &weights[j*col_stride + i];
         float32x4_t w0_3 = vld1q_f32(&w[0]);
         float32x4_t w4_7 = vld1q_f32(&w[4]);
         y0_0_3 = vmlaq_f32(y0_0_3, w0_3, vld1q_dup_f32(&x0[j]));
         y0_4_7 = vmlaq_f32(y0_4_7, w4_7, vld1q_dup_f32(&x0[j]));
         y1_0_3 = vmlaq_f32(y1_0_3, w0_3, vld1q_dup_f32(&x1[j]));
         y1_4_7 = vmlaq_f32(y1_4_7, w4_7, vld1q_dup_f32(&x1[j]));
      }
      vst1q_f32(&out0[i], y0_0_3);
      vst1q_f32(&out0[i+4], y0_4_7);
      vst1q_f32(&out1[i], y1_0_3);
      vst1q_f32(&out1[i+4], y1_4_7);
   }
}

static inline void sparse_sgemv8x4(float *out, const float *w, const int *idx, int rows, const float *x)
{
   int i, j;
   for (i=0;i<rows;i+=8)
   {
      int cols;
      float32x4_t y0_3;
      float32x4_t y4_7;
      y0_3 = vdupq_n_f32(0);
      y4_7 = vdupq_n_f32(0);
      cols = *idx++;
      for (j=0;j<cols;j++)
      {
         int pos;
         float32x4_t xj0, xj1, xj2, xj3;
         pos = (*idx++);
         xj0 = vld1q_dup_f32(&x[pos+0]);
         xj1 = vld1q_dup_f32(&x[pos+1]);
         xj2 = vld1q_dup_f32(&x[pos+2]);
         xj3 = vld1q_dup_f32(&x[pos+3]);
         y0_3 = vmlaq_f32(y0_3, vld1q_f32(&w[0]), xj0);
         y4_7 = vmlaq_f32(y4_7, vld1q_f32(&w[4]), xj0);
         y0_3 = vmlaq_f32(y0_3, vld1q_f32(&w[8]), xj1);
         y4_7 = vmlaq_f32(y4_7, vld1q_f32(&w[12]), xj1);
         y0_3 = vmlaq_f32(y0_3, vld1q_f32(&w[16]), xj2);
         y4_7 = vmlaq_f32(y4_7, vld1q_f32(&w[20]), xj2);
         y0_3 = vmlaq_f32(y0_3, vld1q_f32(&w[24]), xj3);
         y4_7 = vmlaq_f32(y4_7, vld1q_f32(&w[28]), xj3);
         w += 32;
      }
      vst1q_f32(&out[i], y0_3);
      vst1q_f32(&out[i+4], y4_7);
   }
}

#define HAVE_SPARSE_SGEMV8X4_PAIR 1
static inline void sparse_sgemv8x4_pair(
    float * restrict out0,
    float * restrict out1,
    const float * restrict w,
    const int * restrict idx,
    int rows,
    const float * restrict x0,
    const float * restrict x1
)
{
   int i, j;
#define ACCUMULATE_PAIR(acc0_0_3, acc0_4_7, acc1_0_3, acc1_4_7, weights, offset, input_offset, pos) \
      w0_3 = vld1q_f32(&(weights)[offset]); \
      w4_7 = vld1q_f32(&(weights)[(offset)+4]); \
      acc0_0_3 = vmlaq_f32(acc0_0_3, w0_3, vld1q_dup_f32(&x0[(pos)+(input_offset)])); \
      acc0_4_7 = vmlaq_f32(acc0_4_7, w4_7, vld1q_dup_f32(&x0[(pos)+(input_offset)])); \
      acc1_0_3 = vmlaq_f32(acc1_0_3, w0_3, vld1q_dup_f32(&x1[(pos)+(input_offset)])); \
      acc1_4_7 = vmlaq_f32(acc1_4_7, w4_7, vld1q_dup_f32(&x1[(pos)+(input_offset)]))
#define ACCUMULATE_BLOCK(acc0_0_3, acc0_4_7, acc1_0_3, acc1_4_7, weights, pos) \
      ACCUMULATE_PAIR(acc0_0_3, acc0_4_7, acc1_0_3, acc1_4_7, weights, 0, 0, pos); \
      ACCUMULATE_PAIR(acc0_0_3, acc0_4_7, acc1_0_3, acc1_4_7, weights, 8, 1, pos); \
      ACCUMULATE_PAIR(acc0_0_3, acc0_4_7, acc1_0_3, acc1_4_7, weights, 16, 2, pos); \
      ACCUMULATE_PAIR(acc0_0_3, acc0_4_7, acc1_0_3, acc1_4_7, weights, 24, 3, pos)
   /* Interleave independent output-row groups to expose instruction-level
      parallelism without changing any output's accumulation order. */
   for (i=0;i+15<rows;i+=16)
   {
      int cols_a, cols_b, shared_cols;
      const int *idx_a, *idx_b;
      const float *w_a, *w_b;
      float32x4_t a0_0_3 = vdupq_n_f32(0);
      float32x4_t a0_4_7 = vdupq_n_f32(0);
      float32x4_t a1_0_3 = vdupq_n_f32(0);
      float32x4_t a1_4_7 = vdupq_n_f32(0);
      float32x4_t b0_0_3 = vdupq_n_f32(0);
      float32x4_t b0_4_7 = vdupq_n_f32(0);
      float32x4_t b1_0_3 = vdupq_n_f32(0);
      float32x4_t b1_4_7 = vdupq_n_f32(0);
      cols_a = *idx++;
      idx_a = idx;
      w_a = w;
      idx_b = idx_a + cols_a;
      w_b = w_a + 32*cols_a;
      cols_b = *idx_b++;
      shared_cols = cols_a < cols_b ? cols_a : cols_b;
      for (j=0;j<shared_cols;j++)
      {
         int pos_a, pos_b;
         float32x4_t w0_3, w4_7;
         pos_a = *idx_a++;
         pos_b = *idx_b++;
         ACCUMULATE_PAIR(a0_0_3, a0_4_7, a1_0_3, a1_4_7, w_a, 0, 0, pos_a);
         ACCUMULATE_PAIR(b0_0_3, b0_4_7, b1_0_3, b1_4_7, w_b, 0, 0, pos_b);
         ACCUMULATE_PAIR(a0_0_3, a0_4_7, a1_0_3, a1_4_7, w_a, 8, 1, pos_a);
         ACCUMULATE_PAIR(b0_0_3, b0_4_7, b1_0_3, b1_4_7, w_b, 8, 1, pos_b);
         ACCUMULATE_PAIR(a0_0_3, a0_4_7, a1_0_3, a1_4_7, w_a, 16, 2, pos_a);
         ACCUMULATE_PAIR(b0_0_3, b0_4_7, b1_0_3, b1_4_7, w_b, 16, 2, pos_b);
         ACCUMULATE_PAIR(a0_0_3, a0_4_7, a1_0_3, a1_4_7, w_a, 24, 3, pos_a);
         ACCUMULATE_PAIR(b0_0_3, b0_4_7, b1_0_3, b1_4_7, w_b, 24, 3, pos_b);
         w_a += 32;
         w_b += 32;
      }
      for (;j<cols_a;j++)
      {
         int pos_a = *idx_a++;
         float32x4_t w0_3, w4_7;
         ACCUMULATE_BLOCK(a0_0_3, a0_4_7, a1_0_3, a1_4_7, w_a, pos_a);
         w_a += 32;
      }
      for (j=shared_cols;j<cols_b;j++)
      {
         int pos_b = *idx_b++;
         float32x4_t w0_3, w4_7;
         ACCUMULATE_BLOCK(b0_0_3, b0_4_7, b1_0_3, b1_4_7, w_b, pos_b);
         w_b += 32;
      }
      vst1q_f32(&out0[i], a0_0_3);
      vst1q_f32(&out0[i+4], a0_4_7);
      vst1q_f32(&out1[i], a1_0_3);
      vst1q_f32(&out1[i+4], a1_4_7);
      vst1q_f32(&out0[i+8], b0_0_3);
      vst1q_f32(&out0[i+12], b0_4_7);
      vst1q_f32(&out1[i+8], b1_0_3);
      vst1q_f32(&out1[i+12], b1_4_7);
      idx = idx_b;
      w = w_b;
   }
   for (;i<rows;i+=8)
   {
      int cols = *idx++;
      float32x4_t y0_0_3 = vdupq_n_f32(0);
      float32x4_t y0_4_7 = vdupq_n_f32(0);
      float32x4_t y1_0_3 = vdupq_n_f32(0);
      float32x4_t y1_4_7 = vdupq_n_f32(0);
      for (j=0;j<cols;j++)
      {
         int pos = *idx++;
         float32x4_t w0_3, w4_7;
         ACCUMULATE_BLOCK(y0_0_3, y0_4_7, y1_0_3, y1_4_7, w, pos);
         w += 32;
      }
      vst1q_f32(&out0[i], y0_0_3);
      vst1q_f32(&out0[i+4], y0_4_7);
      vst1q_f32(&out1[i], y1_0_3);
      vst1q_f32(&out1[i+4], y1_4_7);
   }
#undef ACCUMULATE_BLOCK
#undef ACCUMULATE_PAIR
}


#define SCALE (128.f*127.f)
#define SCALE_1 (1.f/128.f/127.f)

#define MAX_INPUTS 2048
#define MAX_OUTPUTS 8192

#if __ARM_FEATURE_DOTPROD
static inline int32x4_t vdotprod(int32x4_t acc, int8x16_t a, int8x16_t b) {
  return vdotq_s32(acc, a, b);
}
#else
static inline int32x4_t vdotprod(int32x4_t acc, int8x16_t a, int8x16_t b)
{
  return vpadalq_s16(acc, vpaddq_s16(vmull_s8(vget_low_s8(a), vget_low_s8(b)),  vmull_high_s8(a, b)));
}
#endif

static inline void cgemv8x4(float *_out, const opus_int8 *w, const float *scale, int rows, int cols, const float *_x)
{
   int i, j;
   opus_int32 x_int[MAX_INPUTS/4];
   opus_int8 *x = (opus_int8*) x_int;
   const float32x4_t const127 = vdupq_n_f32(127.);
   for (i=0;i<cols;i+=8) {
      int32x4_t xi0, xi4;
      int16x8_t x_short;
      xi0 = vcvtnq_s32_f32(vmulq_f32(const127, vld1q_f32(&_x[i])));
      xi4 = vcvtnq_s32_f32(vmulq_f32(const127, vld1q_f32(&_x[i+4])));
      x_short = vcombine_s16(vmovn_s32(xi0), vmovn_s32(xi4));
      vst1_s8(&x[i], vmovn_s16(x_short));
   }
   for (i=0;i<rows;i+=8)
   {
      int32x4_t acc0, acc1;
      int32x4_t acc2, acc3;
      acc0 = vdupq_n_s32(0);
      acc1 = vdupq_n_s32(0);
      acc2 = vdupq_n_s32(0);
      acc3 = vdupq_n_s32(0);
      j=0;
      for (;j<cols-4;j+=8)
      {
         int8x16_t vw0, vw1, vw2, vw3, vx0, vx1;
         vx0 = (int8x16_t)vld1q_dup_s32((int*)(void*)&x[j]);
         vw0 = vld1q_s8(w);
         vw1 = vld1q_s8(&w[16]);
         acc0 = vdotprod(acc0, vw0, vx0);
         acc1 = vdotprod(acc1, vw1, vx0);
         vx1 = (int8x16_t)vld1q_dup_s32((int*)(void*)&x[j+4]);
         vw2 = vld1q_s8(&w[32]);
         vw3 = vld1q_s8(&w[48]);
         acc2 = vdotprod(acc2, vw2, vx1);
         acc3 = vdotprod(acc3, vw3, vx1);
         w += 64;
      }
      acc0 = vaddq_s32(acc0, acc2);
      acc1 = vaddq_s32(acc1, acc3);
      for (;j<cols;j+=4)
      {
         int8x16_t vw0, vw1, vx;
         vx = (int8x16_t)vld1q_dup_s32((int*)(void*)&x[j]);
         vw0 = vld1q_s8(w);
         vw1 = vld1q_s8(&w[16]);
         acc0 = vdotprod(acc0, vw0, vx);
         acc1 = vdotprod(acc1, vw1, vx);
         w += 32;
      }
      vst1q_f32(&_out[i], vmulq_f32(vld1q_f32(&scale[i]), vcvtq_f32_s32(acc0)));
      vst1q_f32(&_out[i+4], vmulq_f32(vld1q_f32(&scale[i+4]), vcvtq_f32_s32(acc1)));
   }
}

static inline void sparse_cgemv8x4(float *_out, const opus_int8 *w, const int *idx, const float *scale, int rows, int cols, const float *_x)
{
   int i, j;
   opus_int32 x_int[MAX_INPUTS/4];
   opus_int8 *x = (opus_int8*) x_int;
   const float32x4_t const127 = vdupq_n_f32(127.);
   for (i=0;i<cols;i+=8) {
      int32x4_t xi0, xi4;
      int16x8_t x_short;
      xi0 = vcvtnq_s32_f32(vmulq_f32(const127, vld1q_f32(&_x[i])));
      xi4 = vcvtnq_s32_f32(vmulq_f32(const127, vld1q_f32(&_x[i+4])));
      x_short = vcombine_s16(vmovn_s32(xi0), vmovn_s32(xi4));
      vst1_s8(&x[i], vmovn_s16(x_short));
   }
   for (i=0;i<rows;i+=8)
   {
      int colblocks;
      int32x4_t acc0, acc1;
      acc0 = vdupq_n_s32(0);
      acc1 = vdupq_n_s32(0);
      colblocks = *idx++;
      for (j=0;j<colblocks;j++)
      {
         int pos;
         pos = (*idx++);
         int8x16_t vw0, vw1, vx;
         vx = (int8x16_t)vld1q_dup_s32((int*)(void*)&x[pos]);
         vw0 = vld1q_s8(w);
         vw1 = vld1q_s8(&w[16]);
         acc0 = vdotprod(acc0, vw0, vx);
         acc1 = vdotprod(acc1, vw1, vx);
         w += 32;
      }
      vst1q_f32(&_out[i], vmulq_f32(vld1q_f32(&scale[i]), vcvtq_f32_s32(acc0)));
      vst1q_f32(&_out[i+4], vmulq_f32(vld1q_f32(&scale[i+4]), vcvtq_f32_s32(acc1)));
   }
}


#endif
