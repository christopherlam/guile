#ifndef SCM_STACKCHK_H
#define SCM_STACKCHK_H

/* Copyright 1995-1996,1998,2000,2003,2006,2008-2011,2014,2018
     Free Software Foundation, Inc.

   This file is part of Guile.

   Guile is free software: you can redistribute it and/or modify it
   under the terms of the GNU Lesser General Public License as published
   by the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   Guile is distributed in the hope that it will be useful, but WITHOUT
   ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
   FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
   License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with Guile.  If not, see
   <https://www.gnu.org/licenses/>.  */



#include "libguile/continuations.h"
#include "libguile/debug.h"



/* With debug options we have the possibility to disable stack checking.
 */
#define SCM_STACK_CHECKING_P SCM_STACK_LIMIT

#if defined BUILDING_LIBGUILE
#include "libguile/private-options.h"
# if SCM_STACK_GROWS_UP
#  define SCM_STACK_OVERFLOW_P(s)\
   ((SCM_STACK_PTR (s) - SCM_I_CURRENT_THREAD->base) > SCM_STACK_LIMIT)
# else
#  define SCM_STACK_OVERFLOW_P(s)\
   ((SCM_I_CURRENT_THREAD->base - SCM_STACK_PTR (s)) > SCM_STACK_LIMIT)
# endif
# define SCM_CHECK_STACK\
    {\
       SCM_STACKITEM stack;\
       if (SCM_STACK_OVERFLOW_P (&stack) && scm_stack_checking_enabled_p)\
	 scm_report_stack_overflow ();\
    }
#else
# define SCM_CHECK_STACK /**/
#endif

SCM_API int scm_stack_checking_enabled_p;



SCM_API long scm_stack_size (SCM_STACKITEM *start);
SCM_API void scm_stack_report (void);
SCM_API SCM scm_sys_get_stack_size (void);
SCM_INTERNAL void scm_init_stackchk (void);

#endif  /* SCM_STACKCHK_H */
