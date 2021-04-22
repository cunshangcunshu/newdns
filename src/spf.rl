/* ==========================================================================
 * spf.rl - "spf.c", a Sender Policy Framework library.
 * --------------------------------------------------------------------------
 * Copyright (c) 2009  William Ahern
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to permit
 * persons to whom the Software is furnished to do so, subject to the
 * following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
 * NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 * DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
 * USE OR OTHER DEALINGS IN THE SOFTWARE.
 * ==========================================================================
 */
#include <stddef.h>	/* size_t */
#include <stdlib.h>	/* malloc(3) free(3) */

#include <ctype.h>	/* isgraph(3) isdigit(3) tolower(3) */

#include <string.h>	/* memcpy(3) strlen(3) strsep(3) */

#include <errno.h>	/* EINVAL ENAMETOOLONG errno */

#include <time.h>	/* time(3) */

#include <unistd.h>	/* gethostname(3) */

#include "dns.h"
#include "spf.h"


#if SPF_DEBUG
#include <stdio.h> /* stderr fprintf(3) */

int spf_debug;

#undef SPF_DEBUG
#define SPF_DEBUG spf_debug
#define SPF_TRACE (spf_debug > 1)

#define SPF_SAY_(fmt, ...) fprintf(stderr, fmt "%.1s", __func__, __LINE__, __VA_ARGS__)
#define SPF_SAY(...) SPF_SAY_(">>>> (%s:%d) " __VA_ARGS__, "\n")
#define SPF_HAI SPF_SAY("HAI")
#else
#define SPF_DEBUG 0
#define SPF_TRACE 0

#define SPF_SAY(...)
#define SPF_HAI
#endif /* SPF_DEBUG */


#define spf_lengthof(a) (sizeof (a) / sizeof (a)[0])


static size_t spf_itoa(char *dst, size_t lim, unsigned long i) {
	unsigned r, d = 1000000000, p = 0;
	size_t dp = 0;

	if (i) {
		do {
			if ((r = i / d) || p) {
				i -= r * d;

				p++;

				if (dp < lim)
					dst[dp] = '0' + r;
				dp++;
			}
		} while (d /= 10);
	} else {
		if (dp < lim)
			dst[dp] = '0';
		dp++;
	}

	if (lim)
		dst[SPF_MIN(dp, lim - 1)] = '\0';

	return dp;
} /* spf_itoa() */


static size_t spf_strlcpy(char *dst, const char *src, size_t lim) {
	char *dp = dst; char *de = &dst[lim]; const char *sp = src;

	if (dp < de) {
		do {
			if ('\0' == (*dp++ = *sp++))
				return sp - src - 1;
		} while (dp < de);

		dp[-1]	= '\0';
	}

	while (*sp++ != '\0')
		;;

	return sp - src - 1;
} /* spf_strlcpy() */


static unsigned spf_split(unsigned max, char **argv, char *src, const char *delim) {
	unsigned argc = 0;
	char *arg;

	do {
		if ((arg = strsep(&src, delim)) && *arg && argc < max)
			argv[argc++] = arg;
	} while (arg);

	if (max)
		argv[SPF_MIN(argc, max - 1)] = 0;

	return argc;
} /* spf_split() */


/*
 * Normalize domains:
 *
 *   (1) remove leading dots
 *   (2) remove extra dots
 */
size_t spf_trim(char *dst, const char *src, size_t lim) {
	size_t dp = 0, sp = 0;
	int lc;

	/* trim any leading dot(s) */
	while (src[sp] == '.')
		sp++;

	while ((lc = src[sp])) {
		if (dp < lim)
			dst[dp] = src[sp];

		sp++; dp++;

		/* trim extra dot(s) */
		while (lc == '.' && src[sp] == '.')
			sp++;
	}

	if (lim > 0)
		dst[SPF_MIN(dp, lim - 1)] = '\0';

	return dp;
} /* spf_trim() */


struct spf_sbuf {
	unsigned end;

	_Bool overflow;

	char str[512];
}; /* struct spf_sbuf */

static void sbuf_init(struct spf_sbuf *sbuf) {
	memset(sbuf, 0, sizeof *sbuf);
} /* sbuf_init() */

static _Bool sbuf_putc(struct spf_sbuf *sbuf, int ch) {
	if (sbuf->end < sizeof sbuf->str - 1)
		sbuf->str[sbuf->end++] = ch;
	else
		sbuf->overflow = 1;

	return !sbuf->overflow;
} /* sbuf_putc() */

static _Bool sbuf_puts(struct spf_sbuf *sbuf, const char *src) {
	while (*src && sbuf_putc(sbuf, *src))
		src++;

	return !sbuf->overflow;
} /* sbuf_puts() */

static _Bool sbuf_puti(struct spf_sbuf *sbuf, unsigned long i) {
	if (sizeof sbuf->str <= spf_itoa(&sbuf->str[sbuf->end], sizeof sbuf->str - sbuf->end, i))
		sbuf->overflow = 1;

	return !sbuf->overflow;
} /* sbuf_puti() */


const char *spf_strtype(int type) {
	switch (type) {
	case SPF_ALL:
		return "all";
	case SPF_INCLUDE:
		return "include";
	case SPF_A:
		return "a";
	case SPF_MX:
		return "mx";
	case SPF_PTR:
		return "ptr";
	case SPF_IP4:
		return "ip4";
	case SPF_IP6:
		return "ip6";
	case SPF_EXISTS:
		return "exists";
	case SPF_REDIRECT:
		return "redirect";
	case SPF_EXP:
		return "exp";
	default:
		return "[[[error]]]";
	}
} /* spf_strtype() */




static const struct spf_all all_initializer =
	{ .type = SPF_ALL, .result = SPF_PASS };

static void all_comp(struct spf_sbuf *sbuf, struct spf_all *all) {
	sbuf_putc(sbuf, all->result);
	sbuf_puts(sbuf, "all");
} /* all_comp() */


static const struct spf_include include_initializer =
	{ .type = SPF_INCLUDE, .result = SPF_PASS, .domain = "%{d}" };

static void include_comp(struct spf_sbuf *sbuf, struct spf_include *include) {
	sbuf_putc(sbuf, include->result);
	sbuf_puts(sbuf, "include");
	sbuf_putc(sbuf, ':');
	sbuf_puts(sbuf, include->domain);
} /* include_comp() */


static const struct spf_a a_initializer =
	{ .type = SPF_A, .result = SPF_PASS, .domain = "%{d}", .prefix4 = 32, .prefix6 = 128 };

static void a_comp(struct spf_sbuf *sbuf, struct spf_a *a) {
	sbuf_putc(sbuf, a->result);
	sbuf_puts(sbuf, "a");
	sbuf_putc(sbuf, ':');
	sbuf_puts(sbuf, a->domain);
	sbuf_putc(sbuf, '/');
	sbuf_puti(sbuf, a->prefix4);
	sbuf_puts(sbuf, "//");
	sbuf_puti(sbuf, a->prefix6);
} /* a_comp() */


static const struct spf_mx mx_initializer =
	{ .type = SPF_MX, .result = SPF_PASS, .domain = "%{d}", .prefix4 = 32, .prefix6 = 128 };

static void mx_comp(struct spf_sbuf *sbuf, struct spf_mx *mx) {
	sbuf_putc(sbuf, mx->result);
	sbuf_puts(sbuf, "mx");
	sbuf_putc(sbuf, ':');
	sbuf_puts(sbuf, mx->domain);
	sbuf_putc(sbuf, '/');
	sbuf_puti(sbuf, mx->prefix4);
	sbuf_puts(sbuf, "//");
	sbuf_puti(sbuf, mx->prefix6);
} /* mx_comp() */


static const struct spf_ptr ptr_initializer =
	{ .type = SPF_PTR, .result = SPF_PASS, .domain = "%{d}" };

static void ptr_comp(struct spf_sbuf *sbuf, struct spf_ptr *ptr) {
	sbuf_putc(sbuf, ptr->result);
	sbuf_puts(sbuf, "ptr");
	sbuf_putc(sbuf, ':');
	sbuf_puts(sbuf, ptr->domain);
} /* ptr_comp() */


static const struct spf_ip4 ip4_initializer =
	{ .type = SPF_IP4, .result = SPF_PASS, .prefix = 32 };

static void ip4_comp(struct spf_sbuf *sbuf, struct spf_ip4 *ip4) {
	sbuf_putc(sbuf, ip4->result);
	sbuf_puts(sbuf, "ip4");
	sbuf_putc(sbuf, ':');
	sbuf_puti(sbuf, 0xff & (ntohl(ip4->addr.s_addr) >> 24));
	sbuf_putc(sbuf, '.');
	sbuf_puti(sbuf, 0xff & (ntohl(ip4->addr.s_addr) >> 16));
	sbuf_putc(sbuf, '.');
	sbuf_puti(sbuf, 0xff & (ntohl(ip4->addr.s_addr) >> 8));
	sbuf_putc(sbuf, '.');
	sbuf_puti(sbuf, 0xff & (ntohl(ip4->addr.s_addr) >> 0));
	sbuf_putc(sbuf, '/');
	sbuf_puti(sbuf, ip4->prefix);
} /* ip4_comp() */


static const struct spf_ip6 ip6_initializer =
	{ .type = SPF_IP6, .result = SPF_PASS, .prefix = 128 };

static void ip6_comp(struct spf_sbuf *sbuf, struct spf_ip6 *ip6) {
	static const char tohex[] = "0123456789abcdef";

	sbuf_putc(sbuf, ip6->result);
	sbuf_puts(sbuf, "ip6");

	for (unsigned i = 0; i < 128; i++) {
		if (!(i % 4))
			sbuf_putc(sbuf, ':');

		sbuf_putc(sbuf, tohex[0x0f & (ip6->addr.s6_addr[i] >> 4)]);
		sbuf_putc(sbuf, tohex[0x0f & (ip6->addr.s6_addr[i] >> 0)]);
	}

	sbuf_putc(sbuf, '/');
	sbuf_puti(sbuf, ip6->prefix);
} /* ip6_comp() */


static const struct spf_exists exists_initializer =
	{ .type = SPF_EXISTS, .result = SPF_PASS, .domain = "%{d}" };

static void exists_comp(struct spf_sbuf *sbuf, struct spf_exists *exists) {
	sbuf_putc(sbuf, exists->result);
	sbuf_puts(sbuf, "exists");
	sbuf_putc(sbuf, ':');
	sbuf_puts(sbuf, exists->domain);
} /* exists_comp() */


static const struct spf_redirect redirect_initializer =
	{ .type = SPF_REDIRECT };

static void redirect_comp(struct spf_sbuf *sbuf, struct spf_redirect *redirect) {
	sbuf_puts(sbuf, "redirect");
	sbuf_putc(sbuf, '=');
	sbuf_puts(sbuf, redirect->domain);
} /* redirect_comp() */


static const struct spf_exp exp_initializer =
	{ .type = SPF_EXP };

static void exp_comp(struct spf_sbuf *sbuf, struct spf_exp *exp) {
	sbuf_puts(sbuf, "exp");
	sbuf_putc(sbuf, '=');
	sbuf_puts(sbuf, exp->domain);
} /* exp_comp() */


static const struct spf_unknown unknown_initializer =
	{ .type = SPF_UNKNOWN };

static void unknown_comp(struct spf_sbuf *sbuf, struct spf_unknown *unknown) {
	sbuf_puts(sbuf, unknown->name);
	sbuf_putc(sbuf, '=');
	sbuf_puts(sbuf, unknown->value);
} /* unknown_comp() */


static const struct {
	const void *initializer;
	size_t size;
	void (*comp)();
} spf_term[] = {
	[SPF_ALL]     = { &all_initializer, sizeof all_initializer, &all_comp },
	[SPF_INCLUDE] = { &include_initializer, sizeof include_initializer, &include_comp },
	[SPF_A]       = { &a_initializer, sizeof a_initializer, &a_comp },
	[SPF_MX]      = { &mx_initializer, sizeof mx_initializer, &mx_comp },
	[SPF_PTR]     = { &ptr_initializer, sizeof ptr_initializer, &ptr_comp },
	[SPF_IP4]     = { &ip4_initializer, sizeof ip4_initializer, &ip4_comp },
	[SPF_IP6]     = { &ip6_initializer, sizeof ip6_initializer, &ip6_comp },
	[SPF_EXISTS]  = { &exists_initializer, sizeof exists_initializer, &exists_comp },

	[SPF_REDIRECT] = { &redirect_initializer, sizeof redirect_initializer, &redirect_comp },
	[SPF_EXP]      = { &exp_initializer, sizeof exp_initializer, &exp_comp },
	[SPF_UNKNOWN]  = { &unknown_initializer, sizeof unknown_initializer, &unknown_comp },
}; /* spf_term[] */

static char *term_comp(struct spf_sbuf *sbuf, void *term) {
	spf_term[((struct spf_term *)term)->type].comp(sbuf, term);

	return sbuf->str;
} /* term_comp() */


%%{
	machine spf_rr_parser;
	alphtype unsigned char;

	action oops {
		const unsigned char *part;

		rr->error.lc = fc;

		if (p - (unsigned char *)rdata >= (sizeof rr->error.near / 2))
			part = p - (sizeof rr->error.near / 2);
		else
			part = rdata;

		memset(rr->error.near, 0, sizeof rr->error.near);
		memcpy(rr->error.near, part, SPF_MIN(sizeof rr->error.near - 1, pe - part));

		if (SPF_DEBUG) {
			if (isgraph(rr->error.lc))
				SPF_SAY("`%c' invalid near `%s'", rr->error.lc, rr->error.near);
			else
				SPF_SAY("error near `%s'", rr->error.near);
		}

		error = EINVAL;

		goto error;
	}

	action term_begin {
		result = SPF_PASS;
		memset(&term, 0, sizeof term);
		sbuf_init(&domain);
		prefix4 = 32; prefix6 = 128;
	}

	action term_end {
		if (SPF_TRACE && term.type)
			SPF_SAY("term -> %s", term_comp(&(struct spf_sbuf){ 0 }, &term));
	}

	action all_begin {
		term.all    = all_initializer;
		term.result = result;
	}

	action all_end {
	}

	action include_begin {
		term.include = include_initializer;
		term.result  = result;
	}

	action include_end {
		if (*domain.str)
			spf_trim(term.include.domain, domain.str, sizeof term.include.domain);
	}

	action a_begin {
		term.a      = a_initializer;
		term.result = result;
	}

	action a_end {
		if (*domain.str)
			spf_trim(term.a.domain, domain.str, sizeof term.a.domain);

		term.a.prefix4 = prefix4;
		term.a.prefix6 = prefix6;
	}

	action mx_begin {
		term.mx    = mx_initializer;
		term.result = result;
	}

	action mx_end {
		if (*domain.str)
			spf_trim(term.mx.domain, domain.str, sizeof term.mx.domain);

		term.mx.prefix4 = prefix4;
		term.mx.prefix6 = prefix6;
	}

	action ptr_begin {
		term.ptr    = ptr_initializer;
		term.result = result;
	}

	action ptr_end {
		if (*domain.str)
			spf_trim(term.ptr.domain, domain.str, sizeof term.ptr.domain);
	}

	action ip4_begin {
		term.ip4    = ip4_initializer;
		term.result = result;
	}

	action ip4_end {
		term.ip4.prefix = prefix4;
	}

	action ip6_begin {
		term.ip6    = ip6_initializer;
		term.result = result;
	}

	action ip6_end {
		term.ip6.prefix = prefix6;
	}

	action exists_begin {
		term.exists = exists_initializer;
		term.result = result;
	}

	action exists_end {
		if (*domain.str)
			spf_trim(term.exists.domain, domain.str, sizeof term.exists.domain);
	}

	action redirect_begin {
		term.redirect = redirect_initializer;
	}

	action redirect_end {
		if (*domain.str)
			spf_trim(term.redirect.domain, domain.str, sizeof term.redirect.domain);
	}

	action exp_begin {
		term.exp = exp_initializer;
	}

	action exp_end {
		if (*domain.str)
			spf_trim(term.exp.domain, domain.str, sizeof term.exp.domain);
	}

	action unknown_begin {
		sbuf_init(&name);
		sbuf_init(&value);
	}

	action unknown_end {
		term.unknown = unknown_initializer;

		spf_strlcpy(term.unknown.name, name.str, sizeof term.unknown.name);
		spf_strlcpy(term.unknown.value, value.str, sizeof term.unknown.value);
	}

	#
	# SPF RR grammar per RFC 4408 Sec. 15 App. A.
	#
	blank = [ \t];
	name  = alpha (alnum | "-" | "_" | ".")*;

	delimiter     = "." | "-" | "+" | "," | "/" | "_" | "=";
	transformers  = digit* "r"i?;

	macro_letter  = "s"i | "l"i | "o"i | "d"i | "i"i | "p"i | "v"i | "h"i | "c"i | "r"i | "t"i;
	macro_literal = (0x21 .. 0x24) | (0x26 .. 0x7e);
	macro_expand  = ("%{" macro_letter transformers delimiter* "}") | "%%" | "%_" | "%-";
	macro_string  = (macro_expand | macro_literal)*;

	toplabel       = (digit* alpha alnum*) | (alnum+ "-" (alnum | "-")* alnum);
	domain_end     = ("." toplabel "."?) | macro_expand;
	domain_literal = (0x21 .. 0x24) | (0x26 .. 0x2e) | (0x30 .. 0x7e);
	domain_macro   = (macro_expand | domain_literal)*;
	domain_spec    = (domain_macro domain_end) ${ sbuf_putc(&domain, fc); };

	qnum        = ("0" | ("3" .. "9"))
	            | ("1" digit{0,2})
	            | ("2" ( ("0" .. "4" digit?)?
	                   | ("5" ("0" .. "4")?)?
	                   | ("6" .. "9")?
	                   )
	              );
	ip4_network = qnum "." qnum "." qnum "." qnum;
	ip6_network = (xdigit | ":" | ".")+;

	ip4_cidr_length  = "/" digit+ >{ prefix4 = 0; } ${ prefix4 *= 10; prefix4 += fc - '0'; };
	ip6_cidr_length  = "/" digit+ >{ prefix6 = 0; } ${ prefix6 *= 10; prefix6 += fc - '0'; };
	dual_cidr_length = ip4_cidr_length? ("/" ip6_cidr_length)?;

	unknown  = name >unknown_begin ${ sbuf_putc(&name, fc); }
	           "=" macro_string ${ sbuf_putc(&value, fc); }
	           %unknown_end;
	exp      = "exp"i %exp_begin "=" domain_spec %exp_end;
	redirect = "redirect"i %redirect_begin "=" domain_spec %redirect_end;
	modifier = redirect | exp | unknown;

	exists  = "exists"i %exists_begin ":" domain_spec %exists_end;
	IP6     = "ip6"i %ip6_begin ":" ip6_network ip6_cidr_length?;
	IP4     = "ip4"i %ip4_begin ":" ip4_network ip4_cidr_length?;
	PTR     = "ptr"i %ptr_begin (":" domain_spec)? %ptr_end;
	MX      = "mx"i %mx_begin (":" domain_spec)? dual_cidr_length? %mx_end;
	A       = "a"i %a_begin (":" domain_spec)? dual_cidr_length? %a_end;
	inklude = "include"i %include_begin ":" domain_spec %include_end;
	all     = "all"i %all_begin %all_end;

	mechanism = all | inklude | A | MX | PTR | IP4 | IP6 | exists;
	qualifier = ("+" | "-" | "?" | "~") @{ result = fc; };
	directive = qualifier? mechanism;

	term      = blank+ (directive | modifier) >term_begin %term_end;
	version   = "v=spf1"i;
	record    = version term* blank*;

	main      := record $!oops;
}%%


int spf_rr_parse(struct spf_rr *rr, const void *rdata, size_t rdlen) {
	enum spf_result result = 0;
	struct spf_term term;
	struct spf_sbuf domain, name, value;
	unsigned prefix4 = 0, prefix6 = 0;
	const unsigned char *p, *pe, *eof;
	int cs, error;

	%% write data;

	p   = rdata;
	pe  = p + rdlen;
	eof = pe;

	%% write init;
	%% write exec;

	return 0;
error:
	return error;
} /* spf_rr_parse() */


struct spf_rr *spf_rr_open(const char *qname, enum spf_rtype rtype, int *error) {
	struct spf_rr *rr;

	if (!(rr = malloc(sizeof *rr)))
		goto syerr;

	memset(rr, 0, sizeof *rr);

	SPF_INIT(&rr->terms);

	if (sizeof rr->qname <= spf_trim(rr->qname, qname, sizeof rr->qname))
		{ *error = ENAMETOOLONG; goto error; }

	rr->rtype = rtype;

	return rr;
syerr:
	*error = errno;
error:
	free(rr);

	return 0;
} /* spf_rr_open() */


void spf_rr_close(struct spf_rr *rr) {
	if (!rr)
		return;

	
} /* spf_rr_close() */


struct spf_env *spf_env_init(struct spf_env *env) {
	memset(env->r, 0, sizeof env->r);
	gethostname(env->r, sizeof env->r - 1);

	spf_itoa(env->t, sizeof env->t, (unsigned long)time(0));

	return env;
} /* spf_env_init() */


static size_t spf_env_get_(char **field, int which, struct spf_env *env) {
	switch (tolower((unsigned char)which)) {
	case 's':
		*field = env->s;
		return sizeof env->s;
	case 'l':
		*field = env->l;
		return sizeof env->l;
	case 'o':
		*field = env->o;
		return sizeof env->o;
	case 'd':
		*field = env->d;
		return sizeof env->d;
	case 'i':
		*field = env->i;
		return sizeof env->i;
	case 'p':
		*field = env->p;
		return sizeof env->p;
	case 'v':
		*field = env->v;
		return sizeof env->v;
	case 'h':
		*field = env->h;
		return sizeof env->h;
	case 'c':
		*field = env->c;
		return sizeof env->c;
	case 'r':
		*field = env->r;
		return sizeof env->r;
	case 't':
		*field = env->t;
		return sizeof env->t;
	default:
		*field = 0;
		return 0;
	}
} /* spf_env_get_() */


size_t spf_env_get(char *dst, size_t lim, int which, const struct spf_env *env) {
	char *src;

	if (!spf_env_get_(&src, which, (struct spf_env *)env))
		return 0;

	return spf_strlcpy(dst, src, lim);
} /* spf_env_get() */


size_t spf_env_set(struct spf_env *env, int which, const char *src) {
	size_t lim, len;
	char *dst;

	if (!(lim = spf_env_get_(&dst, which, (struct spf_env *)env)))
		return strlen(src);

	len = spf_strlcpy(dst, src, lim);

	return SPF_MIN(lim - 1, len);
} /* spf_env_set() */


static size_t spf_expand_(char *dst, size_t lim, const char *src, const struct spf_env *env, int *error) {
	char field[512], *part[128], *tmp;
	const char *delim = ".";
	size_t len, dp = 0, sp = 0;
	int macro = 0;
	unsigned keep = 0;
	unsigned i, j, count;
	_Bool tr = 0, rev = 0;

	if (!(macro = *src))
		return 0;

	while (isdigit((unsigned char)src[++sp])) {
		keep *= 10;
		keep += src[sp] - '0';
		tr   = 1;
	}

	if (src[sp] == 'r')
		{ tr = 1; rev = 1; ++sp; }

	if (src[sp]) {
		delim = &src[sp];
		tr = 1;
	}

	if (!(len = spf_env_get(field, sizeof field, macro, env)))
		return 0;
	else if (len >= sizeof field)
		goto toolong;

	if (!tr)
		return spf_strlcpy(dst, field, lim);

	count = spf_split(spf_lengthof(part), part, field, delim);

	if (spf_lengthof(part) <= count)
		goto toolong;

	if (rev) {
		for (i = 0, j = count - 1; i < j; i++, j--) {
			tmp     = part[i];
			part[i] = part[j];
			part[j] = tmp;
		}
	}

	if (keep && keep < count) {
		for (i = 0, j = count - keep; j < count; i++, j++)
			part[i] = part[j];

		count = keep;
	}

	for (i = 0; i < count; i++) {
		if (dp < lim)
			len = spf_strlcpy(&dst[dp], part[i], lim - dp);
		else
			len = strlen(part[i]);

		dp += len;

		if (dp < lim)
			dst[dp] = '.';

		++dp;
	}

	if (dp > 0)
		--dp;

	return dp;
toolong:
	*error = ENAMETOOLONG;

	return 0;
} /* spf_expand_() */


size_t spf_expand(char *dst, size_t lim, const char *src, const struct spf_env *env, int *error) {
	struct spf_sbuf macro;
	size_t len, dp = 0, sp = 0;

	*error = 0;

	do {
		while (src[sp] && src[sp] != '%') {
			if (dp < lim)
				dst[dp] = src[sp];
			++sp; ++dp;
		}

		if (!src[sp])
			break;

		switch (src[++sp]) {
		case '{':
			sbuf_init(&macro);

			while (src[++sp] && src[sp] != '}')
				sbuf_putc(&macro, src[sp]);

			if (src[sp] != '}')
				break;

			++sp;

			len = (dp < lim)
			    ? spf_expand_(&dst[dp], lim - dp, macro.str, env, error)
			    : spf_expand_(0, 0, macro.str, env, error);

			if (!len && *error)
				return 0;

			dp += len;

			break;
		default:
			if (dp < lim)
				dst[dp] = src[sp];
			++sp; ++dp;

			break;
		}
	} while (src[sp]);

	if (lim)
		dst[SPF_MIN(dp, lim - 1)] = '\0';

	return dp;
} /* spf_expand() */


#if SPF_MAIN

#include <stdlib.h>
#include <stdio.h>

#include <string.h>

#include <unistd.h>	/* getopt(3) */


#define panic_(fn, ln, fmt, ...) \
	do { fprintf(stderr, fmt "%.1s", (fn), (ln), __VA_ARGS__); _Exit(EXIT_FAILURE); } while (0)

#define panic(...) panic_(__func__, __LINE__, "spf: (%s:%d) " __VA_ARGS__, "\n")


static int parse(const char *policy) {
	struct spf_rr *rr;
	int error;

	if (!(rr = spf_rr_open("25thandClement.com.", SPF_T_TXT, &error)))
		panic("%s", strerror(error));

	if ((error = spf_rr_parse(rr, policy, strlen(policy))))
		panic("%s", strerror(error));

	spf_rr_close(rr);

	return 0;
} /* parse() */


static int expand(const char *src, const struct spf_env *env) {
	char dst[512];
	int error;

	if (!(spf_expand(dst, sizeof dst, src, env, &error)) && error)
		panic("%s: %s", src, strerror(error));	

	fprintf(stderr, "[%s]\n", dst);

	return 0;
} /* expand() */


#define USAGE \
	"spf [-S:L:O:D:I:P:V:H:C:R:T:vh] parse <POLICY> | expand <MACRO>\n" \
	"  -S EMAIL   <sender>\n" \
	"  -L LOCAL   local-part of <sender>\n" \
	"  -O DOMAIN  domain of <sender>\n" \
	"  -D DOMAIN  <domain>\n" \
	"  -I IP      <ip>\n" \
	"  -P DOMAIN  the validated domain name of <ip>\n" \
	"  -V STR     the string \"in-addr\" if <ip> is ipv4, or \"ip6\" if ipv6\n" \
	"  -H DOMAIN  HELO/EHLO domain\n" \
	"  -C IP      SMTP client IP\n" \
	"  -R DOMAIN  domain name of host performing the check\n" \
	"  -T TIME    current timestamp\n" \
	"  -v         be verbose\n" \
	"  -h         print usage\n" \
	"\n" \
	"Reports bugs to william@25thandClement.com\n"

int main(int argc, char **argv) {
	extern int optind;
	extern char *optarg;
	int opt;
	struct spf_env env;

	spf_debug = 1;

	spf_env_init(&env);

	while (-1 != (opt = getopt(argc, argv, "S:L:O:D:I:P:V:H:C:R:T:vh"))) {
		switch (opt) {
		case 'S':
			/* FALL THROUGH */
		case 'L':
			/* FALL THROUGH */
		case 'O':
			/* FALL THROUGH */
		case 'D':
			/* FALL THROUGH */
		case 'I':
			/* FALL THROUGH */
		case 'P':
			/* FALL THROUGH */
		case 'V':
			/* FALL THROUGH */
		case 'H':
			/* FALL THROUGH */
		case 'C':
			/* FALL THROUGH */
		case 'R':
			/* FALL THROUGH */
		case 'T':
			spf_env_set(&env, opt, optarg);

			break;
		case 'v':
			spf_debug++;

			break;
		case 'h':
			/* FALL THROUGH */
		default:
usage:
			fputs(USAGE, stderr);

			return (opt == 'h')? 0 : EXIT_FAILURE;
		} /* switch() */
	} /* while() */

	argc -= optind;
	argv += optind;

	if (!argc)
		goto usage;

	if (!strcmp(argv[0], "parse") && argc > 1) {
		return parse(argv[1]);
	} else if (!strcmp(argv[0], "expand") && argc > 1) {
		return expand(argv[1], &env);
	} else
		goto usage;

	return 0;
} /* main() */


#endif /* SPF_MAIN */
