// -*- Asm -*-
//
// Copyright (C) 1986, 1987, 1988, 1989, 1990, 1991, 1992, 1993,
//     1994, 1995, 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003,
//     2004, 2005, 2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013,
//     2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021, 2022
//     Massachusetts Institute of Technology
//
// This file is part of MIT/GNU Scheme.
//
// MIT/GNU Scheme is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation; either version 2 of the
// License, or (at your option) any later version.
//
// MIT/GNU Scheme is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MIT/GNU Scheme; if not, write to the Free Software
// Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
// 02110-1301, USA.

// AMD x86-64 assembly language part of the compiled code interface.
// See cmpint.txt, cmpint.zig, cmpintmd/x86-64*, and cmpgc.h for more
// documentation.
//
// Compiled Scheme code uses the following register convention:
//
//	- %rsp contains the Scheme stack pointer, not the C stack
//	  pointer.
//
//	- %rsi contains a pointer to the Scheme interpreter's "register"
//	  block.  This block contains the compiler's copy of MemTop,
//	  the interpreter's registers (val, env, exp, etc.),
//	  temporary locations for compiled code, and the addresses
//	  of various hooks defined in this file.
//
//	- %rdi contains the Scheme free pointer.
//
//	- %rbp contains the Scheme datum mask.
//	The dynamic link (when needed) is in Registers[REGBLOCK_COMPILER_TEMP]
//	Values are returned in Registers[REGBLOCK_VAL]

	.file	"cmpaux-x86-64.s"

#ifdef __APPLE__
#  define SYMBOL(x) _##x

.macro define_c_label name
	.globl	_\name
_\name:
.endm

.macro define_hook_label name
	.globl	_asm_\name
_asm_\name:
.endm
#else
#  define SYMBOL(x) x

.macro define_c_label name
	.globl	\name
\name:
.endm

.macro define_hook_label name
	.globl	asm_\name
asm_\name:
.endm
#endif

.macro define_debugging_label name
	.globl	\name
\name:
.endm

#define TC_LENGTH 6
#define DATUM_LENGTH 58
#define ADDRESS_MASK 0x3ffffffffffffff

#define TC_FALSE 0
#define TC_COMPILED_RETURN 4
#define TC_FLONUM 6
#define TC_TRUE 8
#define TC_FIXNUM 26
#define TC_MANIFEST_NM_VECTOR 39
#define TC_COMPILED_ENTRY 40

#define IMM_DETAGGED_FIXNUM_MINUS_ONE $0xffffffffffffffc0
#define IMM_FALSE $0x0000000000000000
#define IMM_FIXNUM_0 $0x6800000000000000
#define IMM_FLONUM_0 $0x1800000000000000
#define IMM_MANIFEST_NM_VECTOR_1 $0x9c00000000000001
#define IMM_TRUE $0x2000000000000000

// Flonums are represented by tagged pointers to the first of two
// quadwords (sixteen bytes) in memory, the first of which is a
// non-marked vector manifest of length 1, so that the GC will not
// trace the other one, which is an IEEE 754 double-precision format
// value.
#define FLONUM_DATA_OFFSET 8
#define FLONUM_STORAGE_SIZE 16

#define INT_Stack_Overflow 0x1
#define INT_GC 0x4
#define INT_Mask 0xffff

#define REGBLOCK_MEMTOP 0
#define REGBLOCK_INT_MASK 8
#define REGBLOCK_VAL 16
#define REGBLOCK_COMPILER_TEMP 32
#define REGBLOCK_DLINK REGBLOCK_COMPILER_TEMP
#define REGBLOCK_STACK_GUARD 88
#define REGBLOCK_INT_CODE 96

#define regs %rsi
#define rfree %rdi
#define rmask %rbp

	.data
	.align 2

	.globl SYMBOL(C_Stack_Pointer)
	.comm SYMBOL(C_Stack_Pointer),8
	.globl SYMBOL(C_Frame_Pointer)
	.comm SYMBOL(C_Frame_Pointer),8

	.align 8
SYMBOL(flonum_zero):	.double 0.0
SYMBOL(flonum_one):	.double 1.0

	.text
	.align 2

// Call a function (rdi) with an argument (rsi) and a stack pointer and
// frame pointer from inside C.  When it returns, restore the original
// stack pointer.  This kludge is necessary for operating system
// libraries (notably NetBSD's libpthread) that store important
// information in the stack pointer, and get confused when they are
// called in a signal handler for a signal delivered while Scheme has
// set esp to something they consider funny.

define_c_label within_c_stack
	movq	SYMBOL(C_Stack_Pointer)(%rip),%rax
	// Are we currently in C, signalled by having no saved C stack pointer?
	cmpq	$0,%rax
	// Yes: just call the function without messing with rsp.
	je	within_c_stack_from_c
	// No: we have to switch rsp to point into the C stack.
	pushq	%rbp				// Save frame pointer
	movq	%rsp,%rbp
	movq	%rax,%rsp			// Switch to C stack
	movq	$0,SYMBOL(C_Stack_Pointer)(%rip)
	pushq	$0				// Align sp to 16 bytes
	pushq	%rbp				// Save stack pointer
	movq	%rdi,%rax			// arg1 (fn) -> rax
	movq	%rsi,%rdi			// arg2 (arg) -> arg1
	call	*%rax				// call fn(arg)

define_debugging_label within_c_stack_restore
	movq	%rsp,%rax			// Restore C stack ptr
	addq	$16,%rax
	movq	%rax,SYMBOL(C_Stack_Pointer)(%rip)
	popq	%rsp				// Restore stack pointer
						//   and switch back to
						//   Scheme stack
	popq	%rbp				// Restore frame pointer
	ret

define_debugging_label within_c_stack_from_c
	movq	%rdi,%rax			// arg1 (fn) -> rax
	movq	%rsi,%rdi			// arg2 (arg) -> arg1
	jmp	*%rax				// tail-call fn(arg)

// C_to_interface passes control from C into Scheme.
//
//       long C_to_interface (insn_t *ptr=rdi, insn_t *pc=rsi)
//
// It saves the state of the C world (the C frame pointer and stack
// pointer) and then passes control to interface_to_scheme to set up the
// state of the Scheme world.
//
// Note:  The AMD64 ABI mandates that on entry to a function, RSP - 8
// must be a multiple of 0x10; that is, the stack must be 128-bit
// aligned.  We push six quadwords onto the stack, but there is already
// a return address on the stack, for a total of seven quadwords, which
// is misaligned.  Hence we push an extra dummy zero onto the stack,
// which we must pop off in interface_to_C.

define_c_label C_to_interface
	// rdi = compiled entry address
	// rsi = compiled PC
	pushq	%rbp				// Link according
	movq	%rsp,%rbp			//  to C's conventions
	pushq	%rbx				// Save callee-saves
	pushq	%r12				//  registers
	pushq	%r13
	pushq	%r14
	pushq	%r15
	pushq	$0				// Align stack
	movq	%rdi,%rcx			// rcx := entry ptr
	movq	%rsi,%rdx			// rdx := entry pc
						// Preserve frame ptr
	movq	%rbp,SYMBOL(C_Frame_Pointer)(%rip)
						// Preserve stack ptr
	movq	%rsp,SYMBOL(C_Stack_Pointer)(%rip)
	jmp	SYMBOL(interface_to_scheme)

define_hook_label trampoline_to_interface
define_debugging_label trampoline_to_interface
	addq	$16,%rcx			// trampoline storage
	movq	%rcx,%rbx			// argument in rbx
	jmp	scheme_to_interface

define_hook_label scheme_to_interface_call
define_debugging_label scheme_to_interface_call
	popq	%rbx				// pop untagged ret addr
define_debugging_label scheme_to_interface_reentry
//	jmp	scheme_to_interface

// scheme_to_interface passes control from compiled Scheme code to a
// microcode utility.
//
// Arguments:
//
//       rax     return value
//       r9b     utility number (upper 56 bits of r9 are garbage)
//       rbx     first argument
//       rdx     second argument
//       rcx     third argument
//       r8      fourth argument
//
// The microcode utility, a C function following the C amd64 calling
// convention, takes arguments in rdi (utility_result_t pointer), rsi
// (passed in as rbx), rdx, rcx, and r8.  rsi is used by compiled code
// for the registers block, and rdi is used by compiled code for the
// free pointer register, which we have to save here to a location
// unknown to Scheme (the C `Free' variable).

define_hook_label scheme_to_interface
define_debugging_label scheme_to_interface
	movq	%rax,REGBLOCK_VAL(regs)		// Save value
	movq	%rsp,SYMBOL(stack_pointer)(%rip)
	movq	rfree,SYMBOL(Free)(%rip)
	movq	SYMBOL(C_Stack_Pointer)(%rip),%rsp
	movq	SYMBOL(C_Frame_Pointer)(%rip),%rbp

	// Signal to within_c_stack that we are now in C land.
	movq	$0,SYMBOL(C_Stack_Pointer)(%rip)

	subq	$32,%rsp			// alloc struct return;
						// preserve 16-byte alignment
	movq	%rsp,%rdi			// Structure is first argument.
	movq	%rbx,%rsi			// rbx -> second argument.

	// Find the utility.  rbx is now free as a temporary register
	// to hold the utility table.  r9 initially stores the utility
	// number in its low eight bits and possibly garbage in the
	// rest; mask it off and then use it as an index into the
	// utility table, scaled by 8 (bytes per pointer).
	leaq	SYMBOL(utility_table)(%rip),%rbx
	andq	$0xff,%r9
	movq	(%rbx,%r9,8),%rax

	call	*%rax

define_debugging_label scheme_to_interface_return
	// pop utility_result_t contents
	popq	%rax				// interface_dispatch
	popq	%rcx				// interp code / compiled ptr
	popq	%rdx				// interp garbage / compiled pc
	addq	$8,%rsp				// pop alignment padding
	jmp	*%rax				// Invoke handler

define_c_label interface_to_scheme
	// rax = interface_to_scheme [??? -- not referred to]
	// rcx = compiled entry/return address, needed by compiled code
	// rdx = compiled PC, or interface_to_scheme_return
	leaq	SYMBOL(Registers)(%rip),regs
	movq	SYMBOL(Free)(%rip),rfree	// Free pointer = %rdi
	movq	REGBLOCK_VAL(regs),%rax		// Value/dynamic link
	// Restore the C stack pointer, which we zeroed back in
	// scheme_to_interface, for within_c_stack.
	// Restore the C frame pointer too; the interface may have called
	// Re_Enter_Interpreter which probably clobbered both.
	movq	%rsp,SYMBOL(C_Stack_Pointer)(%rip)
	movq	SYMBOL(stack_pointer)(%rip),%rsp
	movq	%rbp,SYMBOL(C_Frame_Pointer)(%rip)
	movq	$ADDRESS_MASK,rmask		// = %rbp
	movq	%rax,%r8			// Preserve if used
	andq	rmask,%r8			// Restore potential dynamic link
	movq	%r8,REGBLOCK_DLINK(regs)
	jmp	*%rdx				// Invoke entry or handler

define_c_label interface_to_scheme_return
	// rcx = compiled return address
	pushq	%rcx
	ret					// Invoke return

define_c_label interface_to_C
	// rax = interface_to_scheme
	// rcx = interpreter code
	// rdx = garbage
	movq	%rcx,%rax			// Set up result
	// We need a dummy register for the POP (which is three bytes
	// shorter than ADD $8,RSP); since we're about to pop into r15
	// anyway, we may as well use that.
	popq	%r15				// Undo stack alignment
	popq	%r15				// Restore callee-saves
	popq	%r14				//  registers
	popq	%r13
	popq	%r12
	popq	%rbx
	leave
	ret

//	Assembly language hooks used to reduce code size.
//	There is no time advantage to using these over using
//	scheme_to_interface (or scheme_to_interface_call), but the
//	code generated by the compiler can be somewhat smaller.

.macro define_jump_indirection name, code
define_hook_label \name
	movb	$0x\code,%r9b
	jmp	scheme_to_interface
.endm

.macro define_call_indirection name, code
define_hook_label \name
	movb	$0x\code,%r9b
	jmp	scheme_to_interface_call
.endm

// Expects compiled entry address (with zero offset) in rbx.
.macro define_reentry_indirection name, code
define_hook_label \name
	movb	$0x\code,%r9b
	jmp	scheme_to_interface
.endm

define_reentry_indirection interrupt_procedure, 1a
define_reentry_indirection interrupt_continuation, 1b
define_jump_indirection interrupt_closure, 18
define_jump_indirection interrupt_continuation_2, 3b

// Expects compiled entry address (with zero offset) in rbx.
define_hook_label interrupt_dlink
	movq	REGBLOCK_DLINK(regs),%rdx
	movb	$0x19,%r9b
	jmp	scheme_to_interface_reentry

	.align 2
define_jump_indirection primitive_apply, 12
define_jump_indirection primitive_lexpr_apply, 13
define_jump_indirection error, 15
define_call_indirection link, 17
define_call_indirection assignment_trap, 1d
define_call_indirection reference_trap, 1f
define_call_indirection safe_reference_trap, 20
define_call_indirection primitive_error, 36

//	Assembly language hooks used to increase speed.

// Stack has untagged return address, then tagged entry, rdx has
// argument count.  If tagged entry is TC_COMPILED_ENTRY of the correct
// arity, set condition codes for equal, store the untagged entry
// address in rcx, and store the PC in rax.  Otherwise, set condition
// codes for not-equal, and leave the stack alone.  Either way, pop and
// return.  Uses r9 as a temporary register.  (rbx, rax, rcx, and rdx
// are all in use already.)
	.align 2
define_hook_label apply_setup
	movq	%rbx,%rax			// Copy for type code
	movq	%rbx,%rcx			// Copy for address
	shrq	$DATUM_LENGTH,%rax		// Select type code
	andq	rmask,%rcx			// Select datum
	cmpb	$TC_COMPILED_ENTRY,%al
	jne	asm_apply_setup_fail
	// We now have a compiled entry, so it is safe to compute the
	// PC.  Do that first, because it sets flags, which are used by
	// the caller.
	movq	-8(%rcx),%rax			// rax := PC offset
	addq	%rcx,%rax			// rax := PC
	// Now check the frame size.  The caller will test the flags
	// again for another conditional jump.
	movsbq	-12(%rcx),%r9			// Extract frame size
	cmpq	%r9,%rdx			// Compare to nargs+1
	jne	asm_apply_setup_fail
	ret

asm_apply_setup_fail:
	// Load the fallback address into rax, where compiled code will
	// jump.
	leaq	asm_sc_apply_generic(%rip),%rax
	ret

.macro define_apply_setup_fixed_size n
	.align 2
define_hook_label apply_setup_size_\n
	movq	%rbx,%rax			// Copy for type code
	movq	%rbx,%rcx			// Copy for address
	shrq	$DATUM_LENGTH,%rax		// Select type code
	andq	rmask,%rcx			// Select datum
	cmpb	$TC_COMPILED_ENTRY,%al
	jne	asm_apply_setup_size_\n\()_fail
	movq	-8(%rcx),%rax			// rax := PC offset
	addq	%rcx,%rax			// rax := PC
	cmpb	$\n,-12(%rcx)			// Compare frame size
	jne	asm_apply_setup_size_\n\()_fail	// to nargs+1
	ret

asm_apply_setup_size_\n\()_fail:
	leaq	asm_sc_apply_generic(%rip),%rax
	movq	$0x\n,%rdx
	ret
.endm

define_apply_setup_fixed_size 1
define_apply_setup_fixed_size 2
define_apply_setup_fixed_size 3
define_apply_setup_fixed_size 4
define_apply_setup_fixed_size 5
define_apply_setup_fixed_size 6
define_apply_setup_fixed_size 7
define_apply_setup_fixed_size 8

	.align 2
define_hook_label sc_apply
	movq	%rbx,%rax			// Copy for type code
	movq	%rbx,%rcx			// Copy for address
	shrq	$DATUM_LENGTH,%rax		// Select type code
	andq	rmask,%rcx			// Select datum
	cmpb	$TC_COMPILED_ENTRY,%al
	jne	asm_sc_apply_generic
	movsbq	-12(%rcx),%rax			// Extract frame size
	cmpq	%rax,%rdx			// Compare to nargs+1
	jne	asm_sc_apply_generic
	movq	-8(%rcx),%rax			// rax := PC offset
	addq	%rcx,%rax			// rax := PC
	jmp	*%rax				// Invoke entry

define_debugging_label asm_sc_apply_generic
	movb	$0x14,%r9b
	jmp	scheme_to_interface

.macro define_apply_fixed_size n
	.align 2
define_hook_label sc_apply_size_\n
	movq	%rbx,%rax			// Copy for type code
	movq	%rbx,%rcx			// Copy for address
	shrq	$DATUM_LENGTH,%rax		// Select type code
	andq	rmask,%rcx			// Select datum
	cmpb	$TC_COMPILED_ENTRY,%al
	jne	asm_sc_apply_generic_\n
	cmpb	$\n,-12(%rcx)			// Compare frame size
	jne	asm_sc_apply_generic_\n		// to nargs+1
	movq	-8(%rcx),%rax			// rax := PC offset
	addq	%rcx,%rax			// rax := PC
	jmp	*%rax				// Invoke entry

asm_sc_apply_generic_\n:
	movq	$\n,%rdx
	movb	$0x14,%r9b
	jmp	scheme_to_interface
.endm

define_apply_fixed_size 1
define_apply_fixed_size 2
define_apply_fixed_size 3
define_apply_fixed_size 4
define_apply_fixed_size 5
define_apply_fixed_size 6
define_apply_fixed_size 7
define_apply_fixed_size 8

// Interrupt checks hook.

define_hook_label set_interrupt_enables
	// stack: untagged return address
	// rax = return value, must preserve
	// rdx = tagged interrupt mask on entry, garbage on exit
	// rcx = temp

	// Mask off tag and other crud and set the interpreter register.
	andq	$INT_Mask,%rdx
	movq	%rdx,REGBLOCK_INT_MASK(regs)

	// This logic more or less follows COMPILER_SETUP_INTERRUPT.

define_debugging_label set_interrupt_enables_determine_memtop
	// Set memtop:
	// (a) to 0 if there's an interrupt pending,
	// (b) to heap_end if GC is disabled, or
	// (c) to heap_alloc_limit if GC is enabled.
	// Forward branches for (a) or (b) so they are statically
	// predicted not-taken.
	testq	%rdx,REGBLOCK_INT_CODE(regs)
	jnz	set_interrupt_enables_pending_interrupt
	testq	$INT_GC,%rdx
	jz	set_interrupt_enables_no_gc
	movq	SYMBOL(heap_alloc_limit)(%rip),%rcx
define_debugging_label set_interrupt_enables_memtop
	movq	%rcx,REGBLOCK_MEMTOP(regs)

define_debugging_label set_interrupt_enables_determine_stack_guard
	// Set stack guard register:
	// (a) to stack_start, if stack overflow interrupt is blocked, or
	// (b) to stack_guard, if stack overflow interrupt is allowed.
	testq	$INT_Stack_Overflow,%rdx
	jz	set_interrupt_enables_no_stackoverflow
	movq	SYMBOL(stack_guard)(%rip),%rcx
define_debugging_label set_interrupt_enables_stack_guard
	movq	%rcx,REGBLOCK_STACK_GUARD(regs)

	// All set!
	ret

define_debugging_label set_interrupt_enables_pending_interrupt
	movq	SYMBOL(memory_block_start)(%rip),%rcx
	jmp	set_interrupt_enables_memtop

define_debugging_label set_interrupt_enables_no_gc
	movq	SYMBOL(heap_end)(%rip),%rcx
	jmp	set_interrupt_enables_memtop

define_debugging_label set_interrupt_enables_no_stackoverflow
	movq	SYMBOL(stack_start)(%rip),%rcx
	jmp	set_interrupt_enables_stack_guard

//	The following code is used by generic arithmetic
//	whether the fixnum case is open-coded in line or not.
//	This takes care of fixnums and flonums so that the common
//	numeric types are much faster than the rare ones
//	(bignums, ratnums, recnums)

	.align 2
asm_generic_return_rax:
	andq	rmask,(%rsp)
	ret					// Invoke return

	.align 2
asm_generic_fixnum_result:
	orb	$TC_FIXNUM,%al
	rorq	$TC_LENGTH,%rax
	jmp	asm_generic_return_rax

	.align 2
asm_generic_flonum_result:
	movq	IMM_MANIFEST_NM_VECTOR_1,%rcx
	movq	%rcx,(rfree)
	movsd	%xmm0,FLONUM_DATA_OFFSET(rfree)
	movq	IMM_FLONUM_0,%rax
	orq	rfree,%rax
	leaq	FLONUM_STORAGE_SIZE(rfree),rfree
	jmp	asm_generic_return_rax

	.align 2
asm_generic_return_sharp_t:
	movq	IMM_TRUE,%rax
	jmp	asm_generic_return_rax

	.align 2
asm_generic_return_sharp_f:
	movq	IMM_FALSE,%rax
	jmp	asm_generic_return_rax

.macro define_unary_operation name, code, fxop, flop
	.align 2
define_hook_label generic_\name
	popq	%rdx
	movq	%rdx,%rax
	shrq	$DATUM_LENGTH,%rax
	cmpb	$TC_FIXNUM,%al
	je	asm_generic_\name\()_fix
	cmpb	$TC_FLONUM,%al
	jne	asm_generic_\name\()_fail

asm_generic_\name\()_flo:
	andq	rmask,%rdx
	movsd	FLONUM_DATA_OFFSET(%rdx),%xmm0
	\flop	SYMBOL(flonum_one)(%rip),%xmm0
	jmp	asm_generic_flonum_result

asm_generic_\name\()_fix:
	movq	%rdx,%rax
	shlq	$TC_LENGTH,%rax
	\fxop	$(1 << TC_LENGTH),%rax
	jno	asm_generic_fixnum_result

asm_generic_\name\()_fail:
	pushq	%rdx
	movb	$0x\code,%r9b
	jmp	scheme_to_interface
.endm

.macro define_unary_predicate name, code, fxjcc, fljcc
	.align 2
define_hook_label generic_\name
	popq	%rdx
	movq	%rdx,%rax
	shrq	$DATUM_LENGTH,%rax
	cmpb	$TC_FIXNUM,%al
	je	asm_generic_\name\()_fix
	cmpb	$TC_FLONUM,%al
	jne	asm_generic_\name\()_fail

asm_generic_\name\()_flo:
	andq	rmask,%rdx
	movsd	FLONUM_DATA_OFFSET(%rdx),%xmm0
	ucomisd	SYMBOL(flonum_zero)(%rip),%xmm0
	\fljcc	asm_generic_return_sharp_t
	jmp	asm_generic_return_sharp_f

asm_generic_\name\()_fix:
	movq	%rdx,%rax
	shlq	$TC_LENGTH,%rax
	cmpq	$0,%rax
	\fxjcc	asm_generic_return_sharp_t
	jmp	asm_generic_return_sharp_f

asm_generic_\name\()_fail:
	pushq	%rdx
	movb	$0x\code,%r9b
	jmp	scheme_to_interface
.endm

.macro define_binary_operation name, code, fxop, flop, setup_shift=1
	.align 2
define_hook_label generic_\name
	popq	%rdx
	popq	%rbx
	movq	%rdx,%rax
	movq	%rbx,%rcx
	shrq	$DATUM_LENGTH,%rax
	shrq	$DATUM_LENGTH,%rcx
	cmpb	%al,%cl
	jne	asm_generic_\name\()_fail
	cmpb	$TC_FIXNUM,%al
	je	asm_generic_\name\()_fix
	cmpb	$TC_FLONUM,%al
	jne	asm_generic_\name\()_fail

asm_generic_\name\()_flo:
	andq	rmask,%rdx
	andq	rmask,%rbx
	movsd	FLONUM_DATA_OFFSET(%rdx),%xmm0
	\flop	FLONUM_DATA_OFFSET(%rbx),%xmm0
	jmp	asm_generic_flonum_result

asm_generic_\name\()_fix:
	movq	%rdx,%rax
	movq	%rbx,%rcx
	.if \setup_shift
	shlq	$TC_LENGTH,%rax
	.else
	andq	rmask,%rax
	.endif
	shlq	$TC_LENGTH,%rcx
	\fxop	%rcx,%rax
	jno	asm_generic_fixnum_result

asm_generic_\name\()_fail:
	pushq	%rbx
	pushq	%rdx
	movb	$0x\code,%r9b
	jmp	scheme_to_interface
.endm

.macro define_binary_predicate name, code, fxjcc, fljcc
	.align 2
define_hook_label generic_\name
	popq	%rdx
	popq	%rbx
	movq	%rdx,%rax
	movq	%rbx,%rcx
	shrq	$DATUM_LENGTH,%rax
	shrq	$DATUM_LENGTH,%rcx
	cmpb	%al,%cl
	jne	asm_generic_\name\()_fail
	cmpb	$TC_FIXNUM,%al
	je	asm_generic_\name\()_fix
	cmpb	$TC_FLONUM,%al
	jne	asm_generic_\name\()_fail

asm_generic_\name\()_flo:
	andq	rmask,%rdx
	andq	rmask,%rbx
	movsd	FLONUM_DATA_OFFSET(%rdx),%xmm0
	ucomisd	FLONUM_DATA_OFFSET(%rbx),%xmm0
	// ucomisd sets the parity bit if the operands are incomparable,
	// i.e. either one is NaN; in that case, return #F.  Otherwise,
	// return #T if fljcc is met, or #F otherwise.
	jp	asm_generic_return_sharp_f
	\fljcc	asm_generic_return_sharp_t
	jmp	asm_generic_return_sharp_f

asm_generic_\name\()_fix:
	shlq	$TC_LENGTH,%rdx
	shlq	$TC_LENGTH,%rbx
	cmpq	%rbx,%rdx
	\fxjcc	asm_generic_return_sharp_t
	jmp	asm_generic_return_sharp_f

asm_generic_\name\()_fail:
	pushq	%rbx
	pushq	%rdx
	movb	$0x\code,%r9b
	jmp	scheme_to_interface
.endm

// Division is hairy.  I'm not sure whether this will do the right
// thing for infinities and NaNs.

define_hook_label generic_divide
	popq	%rdx
	popq	%rbx
	// We want to divide rdx by rbx.  First put the numerator's tag
	// in al and the denominator's tag in cl.
	movq	%rdx,%rax
	movq	%rbx,%rcx
	shrq	$DATUM_LENGTH,%rax
	shrq	$DATUM_LENGTH,%rcx
	cmpb	$TC_FIXNUM,%al
	je	asm_generic_divide_fix
	cmpb	$TC_FLONUM,%al
	jne	asm_generic_divide_fail
	cmpb	$TC_FLONUM,%cl
	je	asm_generic_divide_flo_by_flo
	cmpb	$TC_FIXNUM,%cl
	jne	asm_generic_divide_fail

asm_generic_divide_flo_by_fix:
	// Numerator (rdx) is a flonum, denominator (rbx) is a fixnum.
	movq	%rbx,%rcx
	shlq	$TC_LENGTH,%rcx
	// Division by zero -- bail.
	jz	asm_generic_divide_fail
	andq	rmask,%rdx
	sarq	$TC_LENGTH,%rcx
	movsd	FLONUM_DATA_OFFSET(%rdx),%xmm0
	cvtsi2sdq %rcx,%xmm1
	divsd	%xmm1,%xmm0
	jmp	asm_generic_flonum_result

asm_generic_divide_fix:
	cmpb	$TC_FLONUM,%cl
	jne	asm_generic_divide_fail

asm_generic_divide_fix_by_flo:
	// Numerator (rdx) is a fixnum, denominator (rbx) is a flonum.
	movq	%rbx,%rax
	andq	rmask,%rax
	movq	%rdx,%rcx
	movsd	FLONUM_DATA_OFFSET(%rax),%xmm1
	shlq	$TC_LENGTH,%rcx
	jz	asm_generic_divide_zero_by_flo
	sarq	$TC_LENGTH,%rcx
	cvtsi2sdq %rcx,%xmm0
	divsd	%xmm1,%xmm0
	jmp	asm_generic_flonum_result

asm_generic_divide_zero_by_flo:
	// rcx contains zero, representing a numerator exactly zero.
	// Defer division of 0 by 0.0 or NaN; otherwise, yield exactly
	// zero.
	cvtsi2sdq %rcx,%xmm0
	ucomisd	%xmm1,%xmm0
	jp	asm_generic_divide_fail
	je	asm_generic_divide_fail
	movq	IMM_FIXNUM_0,%rax
	jmp	asm_generic_return_rax

asm_generic_divide_flo_by_flo:
	// Numerator (rdx) and denominator (rbx) are both flonums.
	movq	%rdx,%rax
	movq	%rbx,%rcx
	andq	rmask,%rax
	andq	rmask,%rcx
	movsd	FLONUM_DATA_OFFSET(%rax),%xmm0
	movsd	FLONUM_DATA_OFFSET(%rcx),%xmm1
	ucomisd	SYMBOL(flonum_zero)(%rip),%xmm1
	jp	asm_generic_divide_fail
	je	asm_generic_divide_fail
	divsd	%xmm1,%xmm0
	jmp	asm_generic_flonum_result

asm_generic_divide_fail:
	pushq	%rbx
	pushq	%rdx
	movb	$0x23,%r9b
	jmp	scheme_to_interface

define_unary_operation decrement, 22, subq, subsd
define_unary_operation increment, 26, addq, addsd

define_unary_predicate negative, 2a, jl, jb
define_unary_predicate positive, 2c, jg, ja
define_unary_predicate zero, 2d, je, je

define_binary_operation add, 2b, addq, addsd
define_binary_operation subtract, 28, subq, subsd

// To set up rax, kill its tag, but leave it unshifted; the other
// operand will be shifted already, so that it will already include the
// factor of 2^6 desired in the product.
define_binary_operation multiply, 29, imulq, mulsd, 0

define_binary_predicate equal, 24, je, je
define_binary_predicate greater, 25, jg, ja
define_binary_predicate less, 27, jl, jb

define_jump_indirection generic_quotient, 37
define_jump_indirection generic_remainder, 38
define_jump_indirection generic_modulo, 39

// Input and output in rax, shift count in rcx, all detagged fixnums.
// Return address is at the top of the stack, untagged.  This hook must
// not write to any register other than rax; if it does, the code to
// generate calls to it, in compiler/machines/x86-64/rulfix.scm, must
// clear the register map first.

define_hook_label fixnum_shift
	sarq	$TC_LENGTH,%rcx
	js	asm_fixnum_shift_negative

asm_fixnum_lsh:
	cmpq	$DATUM_LENGTH,%rcx
	jge	asm_fixnum_lsh_overflow
	shlq	%cl,%rax
	ret

asm_fixnum_lsh_overflow:
	xorq	%rax,%rax
	ret

asm_fixnum_shift_negative:
	negq	%rcx

asm_fixnum_rsh:
	cmpq	$DATUM_LENGTH,%rcx
	jge	asm_fixnum_rsh_overflow
	sarq	%cl,%rax

	// Turn rax back into a detagged fixnum by zeroing the low six
	// bits.  We shift right/left rather than ANDing with
	// IMM_DETAGGED_FIXNUM_MINUS_ONE because the latter is too large
	// for an immediate operand of AND and there are no scratch
	// registers available to us right now.
	sarq	$TC_LENGTH,%rax
	salq	$TC_LENGTH,%rax
	ret

asm_fixnum_rsh_overflow:
	cmpq	$0,%rax
	js	asm_fixnum_rsh_overflow_negative

asm_fixnum_rsh_overflow_nonnegative:
	xorq	%rax,%rax
	ret

asm_fixnum_rsh_overflow_negative:
	movq	IMM_DETAGGED_FIXNUM_MINUS_ONE,%rax
	ret

define_c_label sse_read_mxcsr
	enter	$8,$0
	stmxcsr	(%rsp)
	movl	(%rsp),%eax
	leave
	ret

define_c_label sse_write_mxcsr
	enter	$8,$0
	movl	%edi,(%rsp)
	ldmxcsr	(%rsp)
	leave
	ret

define_c_label x87_clear_exceptions
	fnclex
	ret

define_c_label x87_trap_exceptions
	fwait
	ret

define_c_label x87_read_control_word
	enter	$4,$0
	fnstcw	(%rsp)
	movw	(%rsp),%ax
	leave
	ret

define_c_label x87_write_control_word
	enter	$4,$0
	movw	%di,(%rsp)
	fldcw	(%rsp)
	leave
	ret

define_c_label x87_read_status_word
	enter	$4,$0
	fnstsw	(%rsp)
	movw	(%rsp),%ax
	leave
	ret

define_c_label x87_read_environment
	fnstenv	(%rdi)
	// fnstenv masks all exceptions (go figure), so we must load
	// the control word back in order to undo that.
	fldcw	(%rdi)
	ret

define_c_label x87_write_environment
	fldenv	(%rdi)
	ret

// Mark the C stack nonexecutable.

#if defined(__linux__) && defined(__ELF__)
	.section .note.GNU-stack,"",%progbits
#endif
