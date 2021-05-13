
// this is autogenerated file, do not edit it.
#include "ficus/ficus.h"

typedef struct _fx_N16Hashmap__index_t {
   int tag;
   union {
      fx_arr_t IndexByte;
      fx_arr_t IndexWord;
      fx_arr_t IndexLarge;
   } u;
} _fx_N16Hashmap__index_t;

typedef struct {
   int_ rc;
   int_ data;
} _fx_E4Exit_data_t;

typedef struct {
   int_ rc;
   fx_str_t data;
} _fx_E4Fail_data_t;

static void _fx_free_N16Hashmap__index_t(struct _fx_N16Hashmap__index_t* dst)
{
   switch (dst->tag) {
   case 1:
      fx_free_arr(&dst->u.IndexByte); break;
   case 2:
      fx_free_arr(&dst->u.IndexWord); break;
   case 3:
      fx_free_arr(&dst->u.IndexLarge); break;
   default:
      ;
   }
   dst->tag = 0;
}

static void _fx_copy_N16Hashmap__index_t(struct _fx_N16Hashmap__index_t* src, struct _fx_N16Hashmap__index_t* dst)
{
   dst->tag = src->tag;
   switch (src->tag) {
   case 1:
      fx_copy_arr(&src->u.IndexByte, &dst->u.IndexByte); break;
   case 2:
      fx_copy_arr(&src->u.IndexWord, &dst->u.IndexWord); break;
   case 3:
      fx_copy_arr(&src->u.IndexLarge, &dst->u.IndexLarge); break;
   default:
      dst->u = src->u;
   }
}

FX_EXTERN_C void _fx_M7HashmapFM9IndexByteN16Hashmap__index_t1A1b(fx_arr_t* arg0, struct _fx_N16Hashmap__index_t* fx_result)
{
   fx_result->tag = 1;
   fx_copy_arr(arg0, &fx_result->u.IndexByte);
}

FX_EXTERN_C void _fx_M7HashmapFM9IndexWordN16Hashmap__index_t1A1w(fx_arr_t* arg0, struct _fx_N16Hashmap__index_t* fx_result)
{
   fx_result->tag = 2;
   fx_copy_arr(arg0, &fx_result->u.IndexWord);
}

FX_EXTERN_C void _fx_M7HashmapFM10IndexLargeN16Hashmap__index_t1A1i(fx_arr_t* arg0, struct _fx_N16Hashmap__index_t* fx_result)
{
   fx_result->tag = 3;
   fx_copy_arr(arg0, &fx_result->u.IndexLarge);
}

FX_EXTERN_C int _fx_M7HashmapFM9makeindexN16Hashmap__index_t1i(
   int_ size_0,
   struct _fx_N16Hashmap__index_t* fx_result,
   void* fx_fv)
{
   fx_arr_t v_0 = {0};
   fx_arr_t v_1 = {0};
   fx_arr_t v_2 = {0};
   int fx_status = 0;
   if (size_0 <= 256) {
      uint8_t* dstptr_0 = 0;
      {
         const int_ shape_0[] = { size_0 };
         FX_CALL(fx_make_arr(1, shape_0, sizeof(uint8_t), 0, 0, 0, &v_0), _fx_cleanup);
      }
      dstptr_0 = (uint8_t*)v_0.data;
      for (int_ i_0 = 0; i_0 < size_0; i_0++, dstptr_0++) {
         *dstptr_0 = 0u;
      }
      _fx_M7HashmapFM9IndexByteN16Hashmap__index_t1A1b(&v_0, fx_result);
   }
   else if (size_0 <= 65536) {
      uint16_t* dstptr_1 = 0;
      {
         const int_ shape_1[] = { size_0 };
         FX_CALL(fx_make_arr(1, shape_1, sizeof(uint16_t), 0, 0, 0, &v_1), _fx_cleanup);
      }
      dstptr_1 = (uint16_t*)v_1.data;
      for (int_ i_1 = 0; i_1 < size_0; i_1++, dstptr_1++) {
         *dstptr_1 = 0u;
      }
      _fx_M7HashmapFM9IndexWordN16Hashmap__index_t1A1w(&v_1, fx_result);
   }
   else {
      int_* dstptr_2 = 0;
      {
         const int_ shape_2[] = { size_0 };
         FX_CALL(fx_make_arr(1, shape_2, sizeof(int_), 0, 0, 0, &v_2), _fx_cleanup);
      }
      dstptr_2 = (int_*)v_2.data;
      for (int_ i_2 = 0; i_2 < size_0; i_2++, dstptr_2++) {
         *dstptr_2 = 0;
      }
      _fx_M7HashmapFM10IndexLargeN16Hashmap__index_t1A1i(&v_2, fx_result);
   }

_fx_cleanup: ;
   FX_FREE_ARR(&v_0);
   FX_FREE_ARR(&v_1);
   FX_FREE_ARR(&v_2);
   return fx_status;
}

FX_EXTERN_C int _fx_M7HashmapFM4sizei1N16Hashmap__index_t(struct _fx_N16Hashmap__index_t* idx_0, int_* fx_result, void* fx_fv)
{
   int fx_status = 0;
   int tag_0 = idx_0->tag;
   if (tag_0 == 1) {
      *fx_result = FX_ARR_SIZE(idx_0->u.IndexByte, 0);
   }
   else if (tag_0 == 2) {
      *fx_result = FX_ARR_SIZE(idx_0->u.IndexWord, 0);
   }
   else if (tag_0 == 3) {
      *fx_result = FX_ARR_SIZE(idx_0->u.IndexLarge, 0);
   }
   else {
      FX_FAST_THROW(FX_EXN_NoMatchError, _fx_cleanup);
   }

_fx_cleanup: ;
   return fx_status;
}

FX_EXTERN_C int _fx_M7HashmapFM3geti2N16Hashmap__index_ti(
   struct _fx_N16Hashmap__index_t* idx_0,
   int_ i_0,
   int_* fx_result,
   void* fx_fv)
{
   int fx_status = 0;
   int tag_0 = idx_0->tag;
   if (tag_0 == 1) {
      FX_CHKIDX(FX_CHKIDX1(idx_0->u.IndexByte, 0, i_0), _fx_catch_0);
      *fx_result = (int_)(*FX_PTR_1D(uint8_t, idx_0->u.IndexByte, i_0));

   _fx_catch_0: ;
   }
   else if (tag_0 == 2) {
      FX_CHKIDX(FX_CHKIDX1(idx_0->u.IndexWord, 0, i_0), _fx_catch_1);
      *fx_result = (int_)(*FX_PTR_1D(uint16_t, idx_0->u.IndexWord, i_0));

   _fx_catch_1: ;
   }
   else if (tag_0 == 3) {
      FX_CHKIDX(FX_CHKIDX1(idx_0->u.IndexLarge, 0, i_0), _fx_catch_2);
      *fx_result = *FX_PTR_1D(int_, idx_0->u.IndexLarge, i_0);

   _fx_catch_2: ;
   }
   else {
      FX_FAST_THROW(FX_EXN_NoMatchError, _fx_cleanup);
   }

_fx_cleanup: ;
   return fx_status;
}

FX_EXTERN_C int _fx_M7HashmapFM3setv3N16Hashmap__index_tii(
   struct _fx_N16Hashmap__index_t* idx_0,
   int_ i_0,
   int_ newval_0,
   void* fx_fv)
{
   int fx_status = 0;
   int tag_0 = idx_0->tag;
   if (tag_0 == 1) {
      FX_CHKIDX(FX_CHKIDX1(idx_0->u.IndexByte, 0, i_0), _fx_catch_0);
      *FX_PTR_1D(uint8_t, idx_0->u.IndexByte, i_0) = (uint8_t)newval_0;

   _fx_catch_0: ;
   }
   else if (tag_0 == 2) {
      FX_CHKIDX(FX_CHKIDX1(idx_0->u.IndexWord, 0, i_0), _fx_catch_1);
      *FX_PTR_1D(uint16_t, idx_0->u.IndexWord, i_0) = (uint16_t)newval_0;

   _fx_catch_1: ;
   }
   else if (tag_0 == 3) {
      FX_CHKIDX(FX_CHKIDX1(idx_0->u.IndexLarge, 0, i_0), _fx_catch_2);
      *FX_PTR_1D(int_, idx_0->u.IndexLarge, i_0) = newval_0;

   _fx_catch_2: ;
   }
   else {
      FX_FAST_THROW(FX_EXN_NoMatchError, _fx_cleanup);
   }

_fx_cleanup: ;
   return fx_status;
}

FX_EXTERN_C int _fx_M7HashmapFM4copyN16Hashmap__index_t1N16Hashmap__index_t(
   struct _fx_N16Hashmap__index_t* idx_0,
   struct _fx_N16Hashmap__index_t* fx_result,
   void* fx_fv)
{
   int fx_status = 0;
   int tag_0 = idx_0->tag;
   if (tag_0 == 1) {
      fx_arr_t v_0 = {0};
      fx_arr_t tab_0 = {0};
      uint8_t* dstptr_0 = 0;
      fx_copy_arr(&idx_0->u.IndexByte, &tab_0);
      int_ ni_0 = FX_ARR_SIZE(tab_0, 0);
      uint8_t* ptr_tab_0 = FX_PTR_1D(uint8_t, tab_0, 0);
      {
         const int_ shape_0[] = { ni_0 };
         FX_CALL(fx_make_arr(1, shape_0, sizeof(uint8_t), 0, 0, 0, &v_0), _fx_catch_0);
      }
      dstptr_0 = (uint8_t*)v_0.data;
      for (int_ i_0 = 0; i_0 < ni_0; i_0++, dstptr_0++) {
         uint8_t x_0 = ptr_tab_0[i_0]; *dstptr_0 = x_0;
      }
      _fx_M7HashmapFM9IndexByteN16Hashmap__index_t1A1b(&v_0, fx_result);

   _fx_catch_0: ;
      FX_FREE_ARR(&tab_0);
      FX_FREE_ARR(&v_0);
   }
   else if (tag_0 == 2) {
      fx_arr_t v_1 = {0};
      fx_arr_t tab_1 = {0};
      uint16_t* dstptr_1 = 0;
      fx_copy_arr(&idx_0->u.IndexWord, &tab_1);
      int_ ni_1 = FX_ARR_SIZE(tab_1, 0);
      uint16_t* ptr_tab_1 = FX_PTR_1D(uint16_t, tab_1, 0);
      {
         const int_ shape_1[] = { ni_1 };
         FX_CALL(fx_make_arr(1, shape_1, sizeof(uint16_t), 0, 0, 0, &v_1), _fx_catch_1);
      }
      dstptr_1 = (uint16_t*)v_1.data;
      for (int_ i_1 = 0; i_1 < ni_1; i_1++, dstptr_1++) {
         uint16_t x_1 = ptr_tab_1[i_1]; *dstptr_1 = x_1;
      }
      _fx_M7HashmapFM9IndexWordN16Hashmap__index_t1A1w(&v_1, fx_result);

   _fx_catch_1: ;
      FX_FREE_ARR(&tab_1);
      FX_FREE_ARR(&v_1);
   }
   else if (tag_0 == 3) {
      fx_arr_t v_2 = {0};
      fx_arr_t tab_2 = {0};
      int_* dstptr_2 = 0;
      fx_copy_arr(&idx_0->u.IndexLarge, &tab_2);
      int_ ni_2 = FX_ARR_SIZE(tab_2, 0);
      int_* ptr_tab_2 = FX_PTR_1D(int_, tab_2, 0);
      {
         const int_ shape_2[] = { ni_2 };
         FX_CALL(fx_make_arr(1, shape_2, sizeof(int_), 0, 0, 0, &v_2), _fx_catch_2);
      }
      dstptr_2 = (int_*)v_2.data;
      for (int_ i_2 = 0; i_2 < ni_2; i_2++, dstptr_2++) {
         int_ x_2 = ptr_tab_2[i_2]; *dstptr_2 = x_2;
      }
      _fx_M7HashmapFM10IndexLargeN16Hashmap__index_t1A1i(&v_2, fx_result);

   _fx_catch_2: ;
      FX_FREE_ARR(&tab_2);
      FX_FREE_ARR(&v_2);
   }
   else {
      FX_FAST_THROW(FX_EXN_NoMatchError, _fx_cleanup);
   }

_fx_cleanup: ;
   return fx_status;
}

FX_EXTERN_C int fx_init_Hashmap(void)
{
   int fx_status = 0;
   return fx_status;
}

FX_EXTERN_C void fx_deinit_Hashmap(void)
{

}

