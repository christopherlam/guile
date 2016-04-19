/*
 * ports-internal.h - internal-only declarations for ports.
 *
 * Copyright (C) 2013 Free Software Foundation, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301 USA
 */

#ifndef SCM_PORTS_INTERNAL
#define SCM_PORTS_INTERNAL

#include <assert.h>

#include "libguile/_scm.h"
#include "libguile/ports.h"

static inline size_t
scm_port_buffer_size (scm_t_port_buffer *buf)
{
  return scm_c_bytevector_length (buf->bytevector);
}

static inline void
scm_port_buffer_reset (scm_t_port_buffer *buf)
{
  buf->cur = buf->end = SCM_INUM0;
}

static inline void
scm_port_buffer_reset_end (scm_t_port_buffer *buf)
{
  buf->cur = buf->end = scm_from_size_t (scm_port_buffer_size (buf));
}

static inline size_t
scm_port_buffer_can_take (scm_t_port_buffer *buf)
{
  return scm_to_size_t (buf->end) - scm_to_size_t (buf->cur);
}

static inline size_t
scm_port_buffer_can_put (scm_t_port_buffer *buf)
{
  return scm_port_buffer_size (buf) - scm_to_size_t (buf->end);
}

static inline size_t
scm_port_buffer_can_putback (scm_t_port_buffer *buf)
{
  return scm_to_size_t (buf->cur);
}

static inline void
scm_port_buffer_did_take (scm_t_port_buffer *buf, size_t count)
{
  buf->cur = scm_from_size_t (scm_to_size_t (buf->cur) + count);
}

static inline void
scm_port_buffer_did_put (scm_t_port_buffer *buf, size_t count)
{
  buf->end = scm_from_size_t (scm_to_size_t (buf->end) + count);
}

static inline const scm_t_uint8 *
scm_port_buffer_take_pointer (scm_t_port_buffer *buf)
{
  signed char *ret = SCM_BYTEVECTOR_CONTENTS (buf->bytevector);
  return ((scm_t_uint8 *) ret) + scm_to_size_t (buf->cur);
}

static inline scm_t_uint8 *
scm_port_buffer_put_pointer (scm_t_port_buffer *buf)
{
  signed char *ret = SCM_BYTEVECTOR_CONTENTS (buf->bytevector);
  return ((scm_t_uint8 *) ret) + scm_to_size_t (buf->end);
}

static inline size_t
scm_port_buffer_take (scm_t_port_buffer *buf, scm_t_uint8 *dst, size_t count)
{
  count = min (count, scm_port_buffer_can_take (buf));
  if (dst)
    memcpy (dst, scm_port_buffer_take_pointer (buf), count);
  scm_port_buffer_did_take (buf, count);
  return count;
}

static inline size_t
scm_port_buffer_put (scm_t_port_buffer *buf, const scm_t_uint8 *src,
                     size_t count)
{
  count = min (count, scm_port_buffer_can_put (buf));
  if (src)
    memcpy (scm_port_buffer_put_pointer (buf), src, count);
  scm_port_buffer_did_put (buf, count);
  return count;
}

static inline void
scm_port_buffer_putback (scm_t_port_buffer *buf, const scm_t_uint8 *src,
                         size_t count)
{
  assert (count <= scm_to_size_t (buf->cur));

  /* Sometimes used to move around data within a buffer, so we must use
     memmove.  */
  buf->cur = scm_from_size_t (scm_to_size_t (buf->cur) - count);
  memmove (SCM_BYTEVECTOR_CONTENTS (buf->bytevector) + scm_to_size_t (buf->cur),
           src, count);
}

enum scm_port_encoding_mode {
  SCM_PORT_ENCODING_MODE_UTF8,
  SCM_PORT_ENCODING_MODE_LATIN1,
  SCM_PORT_ENCODING_MODE_ICONV
};

typedef enum scm_port_encoding_mode scm_t_port_encoding_mode;

/* This is a separate object so that only those ports that use iconv
   cause finalizers to be registered.  */
struct scm_iconv_descriptors
{
  /* input/output iconv conversion descriptors */
  void *input_cd;
  void *output_cd;
};

typedef struct scm_iconv_descriptors scm_t_iconv_descriptors;

struct scm_port_internal
{
  unsigned at_stream_start_for_bom_read  : 1;
  unsigned at_stream_start_for_bom_write : 1;
  scm_t_port_encoding_mode encoding_mode;
  scm_t_iconv_descriptors *iconv_descriptors;
  SCM alist;
};

typedef struct scm_port_internal scm_t_port_internal;

#define SCM_UNICODE_BOM  0xFEFFUL  /* Unicode byte-order mark */

#define SCM_PORT_GET_INTERNAL(x)  (SCM_PTAB_ENTRY(x)->internal)

SCM_INTERNAL scm_t_iconv_descriptors *
scm_i_port_iconv_descriptors (SCM port, scm_t_port_rw_active mode);

#endif
