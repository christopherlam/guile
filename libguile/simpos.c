/* Copyright (C) 1995, 1996, 1997, 1998, 2000, 2001, 2003, 2004, 2009,
 *   2010, 2012, 2013, 2014 Free Software Foundation, Inc.
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



#ifdef HAVE_CONFIG_H
#  include <config.h>
#endif

#include <errno.h>
#include <signal.h>  /* for SIG constants */
#include <stdlib.h>  /* for getenv */
#include <stdio.h>

#include "libguile/_scm.h"

#include "libguile/scmsigs.h"
#include "libguile/strings.h"

#include "libguile/validate.h"
#include "libguile/simpos.h"
#include "libguile/dynwind.h"

#ifdef HAVE_STRING_H
#include <string.h>
#endif
#include <unistd.h>
#if HAVE_SYS_WAIT_H
# include <sys/wait.h>
#endif

#include "posix.h"


extern int system();


#ifdef HAVE_SYSTEM
SCM_DEFINE (scm_system, "system", 0, 1, 0,
           (SCM cmd),
	    "Execute @var{cmd} using the operating system's \"command\n"
	    "processor\".  Under Unix this is usually the default shell\n"
	    "@code{sh}.  The value returned is @var{cmd}'s exit status as\n"
	    "returned by @code{waitpid}, which can be interpreted using\n"
	    "@code{status:exit-val} and friends.\n"
	    "\n"
	    "If @code{system} is called without arguments, return a boolean\n"
	    "indicating whether the command processor is available.")
#define FUNC_NAME s_scm_system
{
  int rv, eno;
  char *c_cmd;
  
  if (SCM_UNBNDP (cmd))
    {
      rv = system (NULL);
      return scm_from_bool(rv);
    }  
  SCM_VALIDATE_STRING (1, cmd);
  errno = 0;
  c_cmd = scm_to_locale_string (cmd);
  rv = system (c_cmd);
  eno = errno; free (c_cmd); errno = eno;
  if (rv == -1 || (rv == 127 && errno != 0))
    SCM_SYSERROR;
  return scm_from_int (rv);
}
#undef FUNC_NAME
#endif /* HAVE_SYSTEM */


#ifdef HAVE_SYSTEM
#ifdef HAVE_WAITPID


SCM_DEFINE (scm_system_star, "system*", 0, 0, 1,
           (SCM args),
"Execute the command indicated by @var{args}.  The first element must\n"
"be a string indicating the command to be executed, and the remaining\n"
"items must be strings representing each of the arguments to that\n"
"command.\n"
"\n"
"This function returns the exit status of the command as provided by\n"
"@code{waitpid}.  This value can be handled with @code{status:exit-val}\n"
"and the related functions.\n"
"\n"
"@code{system*} is similar to @code{system}, but accepts only one\n"
"string per-argument, and performs no shell interpretation.  The\n"
"command is executed using fork and execlp.  Accordingly this function\n"
"may be safer than @code{system} in situations where shell\n"
"interpretation is not required.\n"
"\n"
"Example: (system* \"echo\" \"foo\" \"bar\")")
#define FUNC_NAME s_scm_system_star
{
  if (scm_is_null (args))
    SCM_WRONG_NUM_ARGS ();

  if (scm_is_pair (args))
    {
      SCM oldint;
      SCM oldquit;
      SCM sig_ign;
      SCM sigint;
      SCM sigquit;
      int pid;
      char **execargv;

      /* allocate before fork */
      execargv = scm_i_allocate_string_pointers (args);

      /* make sure the child can't kill us (as per normal system call) */
      sig_ign = scm_from_ulong ((unsigned long) SIG_IGN);
      sigint = scm_from_int (SIGINT);
      sigquit = scm_from_int (SIGQUIT);
      oldint = scm_sigaction (sigint, sig_ign, SCM_UNDEFINED);
      oldquit = scm_sigaction (sigquit, sig_ign, SCM_UNDEFINED);
      
      pid = fork ();
      if (pid == 0)
        {
          /* child */
	  execvp (execargv[0], execargv);

	  /* Something went wrong.  */
	  fprintf (stderr, "In execvp of %s: %s\n",
		   execargv[0], strerror (errno));

	  /* Exit directly instead of throwing, because otherwise this
	     process may keep on running.  Use exit status 127, like
	     shells in this case, as per POSIX
	     <http://pubs.opengroup.org/onlinepubs/007904875/utilities/xcu_chap02.html#tag_02_09_01_01>.  */
	  _exit (127);
        }
      else
        {
          /* parent */
          int wait_result, status;

          if (pid == -1)
            SCM_SYSERROR;

          SCM_SYSCALL (wait_result = waitpid (pid, &status, 0));
          if (wait_result == -1)
	    SCM_SYSERROR;
          scm_sigaction (sigint, SCM_CAR (oldint), SCM_CDR (oldint));
          scm_sigaction (sigquit, SCM_CAR (oldquit), SCM_CDR (oldquit));

          return scm_from_int (status);
        }
    }
  else
    SCM_WRONG_TYPE_ARG (1, args);
}
#undef FUNC_NAME
#endif /* HAVE_WAITPID */
#endif /* HAVE_SYSTEM */


SCM_DEFINE (scm_getenv, "getenv", 1, 0, 0, 
            (SCM nam),
	    "Looks up the string @var{nam} in the current environment.  The return\n"
	    "value is @code{#f} unless a string of the form @code{NAME=VALUE} is\n"
	    "found, in which case the string @code{VALUE} is returned.")
#define FUNC_NAME s_scm_getenv
{
  char *val;
  char *var = scm_to_locale_string (nam);
  val = getenv (var);
  free (var);
  return val ? scm_from_locale_string (val) : SCM_BOOL_F;
}
#undef FUNC_NAME

/* Get an integer from an environment variable.  */
int
scm_getenv_int (const char *var, int def)
{
  char *end = 0;
  char *val = getenv (var);
  long res = def;
  if (!val)
    return def;
  res = strtol (val, &end, 10);
  if (end == val)
    return def;
  return res;
}

/* simple exit, without unwinding the scheme stack or flushing ports.  */
SCM_DEFINE (scm_primitive_exit, "primitive-exit", 0, 1, 0, 
            (SCM status),
	    "Terminate the current process without unwinding the Scheme\n"
	    "stack.  The exit status is @var{status} if supplied, otherwise\n"
	    "zero.")
#define FUNC_NAME s_scm_primitive_exit
{
  int cstatus = 0;
  if (!SCM_UNBNDP (status))
    cstatus = scm_to_int (status);
  exit (cstatus);
}
#undef FUNC_NAME

SCM_DEFINE (scm_primitive__exit, "primitive-_exit", 0, 1, 0,
            (SCM status),
	    "Terminate the current process using the _exit() system call and\n"
	    "without unwinding the Scheme stack.  The exit status is\n"
	    "@var{status} if supplied, otherwise zero.\n"
	    "\n"
	    "This function is typically useful after a fork, to ensure no\n"
	    "Scheme cleanups or @code{atexit} handlers are run (those\n"
	    "usually belonging in the parent rather than the child).")
#define FUNC_NAME s_scm_primitive__exit
{
  int cstatus = 0;
  if (!SCM_UNBNDP (status))
    cstatus = scm_to_int (status);
  _exit (cstatus);
}
#undef FUNC_NAME



void
scm_init_simpos ()
{
#include "libguile/simpos.x"
}


/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
