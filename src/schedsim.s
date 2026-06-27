# schedsim.s - CmpE 230 Project 2 (Spring 2026)
#
# CPU scheduling simulator in x86-64 assembly. Reads one line from stdin,
# figures out which algorithm we want (FCFS / SJF / SRTF / PF / RR), parses
# the process list, runs the simulation cycle by cycle and prints the
# resulting timeline string to stdout.
#
# We don't link libc here, only direct syscalls (read=0, write=1, exit=60).
# Everything lives in .bss so we never need malloc/brk either.
#
# Build:
#   as -o schedsim.o src/schedsim.s
#   ld -o schedsim   schedsim.o

.equ MAX_PROC, 16          # spec says max 10, we keep some slack
.equ IN_CAP,   1024        # input buffer size (one line, plenty)
.equ OUT_CAP,  2048        # output line is capped at 1024 chars by spec
.equ RR_CAP,   16          # ring buffer slots for the RR queue


# ---- BSS: uninitialised data (zero-filled by the loader) -----------------
.section .bss

# Process info kept as parallel arrays. Index = order of appearance in the
# input. We tried a "struct" layout first but indexing was painful in asm,
# so five separate arrays was easier to write.
proc_id:        .space MAX_PROC          # one ASCII letter per process
proc_burst:     .space MAX_PROC*4        # original burst (we keep this)
proc_arrival:   .space MAX_PROC*4        # arrival time
proc_remaining: .space MAX_PROC*4        # cycles still to run (decremented)
proc_priority:  .space MAX_PROC*4        # only used by PF

# Misc globals
proc_count:     .space 4                 # how many processes were parsed
quantum:        .space 4                 # RR quantum (last token in input)
algo:           .space 4                 # 0=FCFS 1=SJF 2=SRTF 3=PF 4=RR

# I/O buffers
input_buf:      .space IN_CAP
output_buf:     .space OUT_CAP
output_len:     .space 4

# Queue for round robin: each slot holds one process index (1 byte is plenty)
rr_queue:       .space RR_CAP
rr_head:        .space 4                 # next slot to pop from
rr_tail:        .space 4                 # next slot to push to
rr_size:        .space 4                 # current occupancy


# ---- TEXT: the actual code -----------------------------------------------
.section .text
.global _start

# Entry point. Layout of the program:
#   1) read the whole input line into input_buf
#   2) parse the algorithm name + the process descriptors
#   3) jump into the right scheduler, which fills output_buf
#   4) write output_buf out and exit
_start:
    # read(0, input_buf, IN_CAP) -- we just slurp everything in one go.
    # The trailing NUL bytes (BSS is zeroed) act as our end-of-input sentinel.
    xorl    %eax, %eax                  # rax = 0 -> read syscall
    xorl    %edi, %edi                  # rdi = 0 -> stdin
    leaq    input_buf(%rip), %rsi
    movq    $IN_CAP, %rdx
    syscall

    # %rsi is going to be our parse cursor for everything that follows.
    leaq    input_buf(%rip), %rsi
    call    parse_algo
    call    parse_processes

    # Pick the scheduler. We just compare the algo number against each
    # constant -- a jump table would be fancier but this is only 5 entries.
    movl    algo(%rip), %eax
    cmpl    $0, %eax
    je      .start_fcfs
    cmpl    $1, %eax
    je      .start_sjf
    cmpl    $2, %eax
    je      .start_srtf
    cmpl    $3, %eax
    je      .start_pf
    # if we got here algo must be 4 (RR)
    call    run_rr
    jmp     write_and_exit
.start_fcfs:
    call    run_fcfs
    jmp     write_and_exit
.start_sjf:
    call    run_sjf
    jmp     write_and_exit
.start_srtf:
    call    run_srtf
    jmp     write_and_exit
.start_pf:
    call    run_pf
    jmp     write_and_exit


# parse_algo: figure out which algorithm we're running.
#
# We only need to look at the first one or two characters because every
# algo name has a unique prefix:
#   F.. -> FCFS    P.. -> PF      R.. -> RR
#   SJ. -> SJF     SR. -> SRTF
#
# After the dispatch we fast-forward past the rest of the name and eat the
# space separator that comes before the first process descriptor.
parse_algo:
    movb    (%rsi), %al
    cmpb    $'F', %al
    je      .pa_fcfs
    cmpb    $'P', %al
    je      .pa_pf
    cmpb    $'R', %al
    je      .pa_rr
    # not F/P/R, so it has to start with S. Peek at the second char to
    # tell SJF apart from SRTF.
    movb    1(%rsi), %al
    cmpb    $'J', %al
    je      .pa_sjf
    movl    $2, algo(%rip)              # SRTF
    jmp     .pa_skip
.pa_fcfs:
    movl    $0, algo(%rip)
    jmp     .pa_skip
.pa_sjf:
    movl    $1, algo(%rip)
    jmp     .pa_skip
.pa_pf:
    movl    $3, algo(%rip)
    jmp     .pa_skip
.pa_rr:
    movl    $4, algo(%rip)
    # fall into .pa_skip

# Skip the rest of the algorithm token (any non-space chars), then eat
# exactly one space. If we hit '\n' or '\0' first we just return -- that
# would be a weird input but we shouldn't crash on it.
.pa_skip:
1:  movb    (%rsi), %al
    cmpb    $' ', %al
    je      2f
    cmpb    $'\n', %al
    je      3f
    testb   %al, %al
    jz      3f
    incq    %rsi
    jmp     1b
2:  incq    %rsi                        # consume the single space
3:  ret


# parse_processes: walk the rest of the line and fill in the proc_* arrays.
#
# Each process descriptor looks like "X-burst" or "X-burst-arrival" or
# "X-burst-arrival-priority" depending on which algorithm we picked.
# For RR there's an extra trailing integer at the end of the line which
# is the quantum. We tell the quantum apart from a process descriptor
# by checking if the second character is a hyphen -- the quantum has no
# hyphen because it's just digits.
parse_processes:
    movl    $0, proc_count(%rip)

.pp_loop:
    movb    (%rsi), %al
    testb   %al, %al
    je      .pp_done                    # NUL -> end of input
    cmpb    $'\n', %al
    je      .pp_done                    # newline -> we're done

    # Token starts here. If second char isn't '-', it's the RR quantum.
    movb    1(%rsi), %al
    cmpb    $'-', %al
    jne     .pp_quantum

    # ----- this is a process descriptor -----
    movl    proc_count(%rip), %r12d     # i = current index
    movb    (%rsi), %al
    movb    %al, proc_id(,%r12,1)       # save the letter
    addq    $2, %rsi                    # skip "X-"

    # burst (always present)
    call    read_uint
    movl    proc_count(%rip), %r12d     # reload i (read_uint can clobber)
    leaq    proc_burst(%rip), %r13
    movl    %eax, (%r13,%r12,4)
    leaq    proc_remaining(%rip), %r13
    movl    %eax, (%r13,%r12,4)         # remaining starts equal to burst

    # decide which extra fields exist based on the algorithm:
    #   SJF / RR -> none
    #   FCFS / SRTF -> arrival
    #   PF -> arrival + priority
    movl    algo(%rip), %ecx
    cmpl    $1, %ecx
    je      .pp_record_done             # SJF
    cmpl    $4, %ecx
    je      .pp_record_done             # RR

    # arrival
    incq    %rsi                        # eat '-'
    call    read_uint
    movl    proc_count(%rip), %r12d
    leaq    proc_arrival(%rip), %r13
    movl    %eax, (%r13,%r12,4)

    cmpl    $3, algo(%rip)              # only PF has priority
    jne     .pp_record_done
    incq    %rsi
    call    read_uint
    movl    proc_count(%rip), %r12d
    leaq    proc_priority(%rip), %r13
    movl    %eax, (%r13,%r12,4)

.pp_record_done:
    incl    proc_count(%rip)

    # eat one space and loop. if there isn't a space the next iter will
    # detect end-of-input on its own.
    movb    (%rsi), %al
    cmpb    $' ', %al
    jne     .pp_loop
    incq    %rsi
    jmp     .pp_loop

.pp_quantum:
    call    read_uint
    movl    %eax, quantum(%rip)
    jmp     .pp_done

.pp_done:
    ret


# read_uint: parse a non-negative decimal int starting at %rsi, return it
# in %eax, and advance %rsi past the digits. Stops as soon as we see
# something that isn't a digit (space, '-', '\n', '\0', whatever).
#
# Standard "acc = acc*10 + (c - '0')" pattern. The 3-operand form of imul
# is so we don't trash %edx (we need it for the digit value).
read_uint:
    xorl    %eax, %eax
1:  movb    (%rsi), %dl
    cmpb    $'0', %dl
    jb      2f
    cmpb    $'9', %dl
    ja      2f
    imull   $10, %eax, %eax
    subb    $'0', %dl
    movzbl  %dl, %edx
    addl    %edx, %eax
    incq    %rsi
    jmp     1b
2:  ret


# emit_char: append the byte in %dil to output_buf, bump output_len.
# We only clobber r10 and r11 here so callers can keep using r12-r15 freely.
emit_char:
    movl    output_len(%rip), %r10d
    leaq    output_buf(%rip), %r11
    movb    %dil, (%r11,%r10,1)
    incl    output_len(%rip)
    ret


# emit_n: append %ecx copies of %dil to output_buf. Used for the long
# bursts in FCFS/SJF and for the X-padding in RR. If %ecx <= 0 we just
# return without doing anything (saves us a lot of "is it zero?" checks
# in the callers).
emit_n:
    testl   %ecx, %ecx
    jle     2f
    movl    output_len(%rip), %r10d
    leaq    output_buf(%rip), %r11
1:  movb    %dil, (%r11,%r10,1)
    incl    %r10d
    decl    %ecx
    jnz     1b
    movl    %r10d, output_len(%rip)
2:  ret


# any_remaining: scan proc_remaining[] and return 1 in %eax as soon as we
# see a non-zero entry, otherwise 0. Used by SRTF/PF to figure out
# whether "no candidate" means "we're done" or "we just need to idle".
any_remaining:
    xorl    %ecx, %ecx
1:  cmpl    proc_count(%rip), %ecx
    jge     2f
    movl    proc_remaining(,%rcx,4), %eax
    testl   %eax, %eax
    jnz     3f
    incl    %ecx
    jmp     1b
2:  xorl    %eax, %eax
    ret
3:  movl    $1, %eax
    ret


# write_and_exit: dump output_buf to stdout, then exit(0).
# We do NOT add a trailing '\n' -- TA confirmed on Piazza that's
# preferred ("preferably not"), and check_output strips trailing
# whitespace anyway so it wouldn't matter for grading.
write_and_exit:
    movl    $1, %eax                    # rax = 1 -> write
    movl    $1, %edi                    # rdi = 1 -> stdout
    leaq    output_buf(%rip), %rsi
    movslq  output_len(%rip), %rdx      # write expects 64-bit length
    syscall

    movl    $60, %eax                   # rax = 60 -> exit
    xorl    %edi, %edi
    syscall


# ===========================================================================
# Schedulers
# ---------------------------------------------------------------------------
# All four scan-based schedulers (FCFS, SJF, SRTF, PF) share the same
# skeleton: a "scan" loop that picks one candidate, then a "step" that
# emits some chars and updates state. RR is different (queue-based) and
# lives further down.
#
# Register convention used inside every scheduler:
#   %r12d  current_time     (kept across the outer loop)
#   %r13d  chosen index     (-1 means "no candidate found this scan")
#   %r14d  best metric so far during the scan
#   %r15d  loop counter i
#   %ebx   secondary key when we need one (PF priority, RR run count)
#
# The helpers above (emit_char, emit_n, etc.) only touch r10/r11 plus
# their declared inputs in dil/ecx, so we never need to push r12-r15
# or rbx onto the stack while we call them.
# ===========================================================================


# FCFS - non-preemptive, smallest arrival wins, ties go to whoever
# appeared first in the input. Once a process starts it runs to completion.
run_fcfs:
    xorl    %r12d, %r12d                # current_time = 0

.fcfs_step:
    # reset "best so far"
    movl    $-1, %r13d
    movl    $0x7fffffff, %r14d          # treat as "+infinity"
    xorl    %r15d, %r15d                # i = 0
.fcfs_scan:
    cmpl    proc_count(%rip), %r15d
    jge     .fcfs_pick_done
    # skip processes that already finished
    movl    proc_remaining(,%r15,4), %eax
    testl   %eax, %eax
    jz      .fcfs_scan_next
    # otherwise compare arrival to current best
    movl    proc_arrival(,%r15,4), %eax
    cmpl    %r14d, %eax
    jge     .fcfs_scan_next             # >= keeps the earlier candidate
    movl    %eax, %r14d
    movl    %r15d, %r13d
.fcfs_scan_next:
    incl    %r15d
    jmp     .fcfs_scan

.fcfs_pick_done:
    cmpl    $-1, %r13d
    je      .fcfs_done                  # nobody left -> exit

    # If the chosen process hasn't arrived yet, fill the gap with X.
    cmpl    %r12d, %r14d
    jle     .fcfs_no_idle
    movl    %r14d, %ecx
    subl    %r12d, %ecx
    movl    $'X', %edi
    call    emit_n
    movl    %r14d, %r12d                # advance clock to the arrival time
.fcfs_no_idle:

    # Run the process to completion (FCFS doesn't preempt).
    movzbl  proc_id(,%r13,1), %edi
    movl    proc_remaining(,%r13,4), %ecx
    addl    %ecx, %r12d                 # clock += burst
    movl    $0, proc_remaining(,%r13,4) # mark as done
    call    emit_n
    jmp     .fcfs_step

.fcfs_done:
    ret


# SJF - everyone arrives at t=0, pick by smallest burst, run to completion.
# Same shape as FCFS but no idle handling and we compare remaining instead
# of arrival.
run_sjf:
.sjf_step:
    movl    $-1, %r13d
    movl    $0x7fffffff, %r14d
    xorl    %r15d, %r15d
.sjf_scan:
    cmpl    proc_count(%rip), %r15d
    jge     .sjf_pick_done
    movl    proc_remaining(,%r15,4), %eax
    testl   %eax, %eax
    jz      .sjf_scan_next              # already finished (also handles burst=0)
    cmpl    %r14d, %eax
    jge     .sjf_scan_next              # >= keeps the earlier one (input order)
    movl    %eax, %r14d
    movl    %r15d, %r13d
.sjf_scan_next:
    incl    %r15d
    jmp     .sjf_scan

.sjf_pick_done:
    cmpl    $-1, %r13d
    je      .sjf_done

    movzbl  proc_id(,%r13,1), %edi
    movl    proc_remaining(,%r13,4), %ecx
    movl    $0, proc_remaining(,%r13,4)
    call    emit_n
    jmp     .sjf_step

.sjf_done:
    ret


# SRTF - preemptive version of SJF. Re-pick every single tick and emit one
# character at a time. "Ready" means arrival <= current_time AND remaining > 0.
run_srtf:
    xorl    %r12d, %r12d

.srtf_step:
    movl    $-1, %r13d
    movl    $0x7fffffff, %r14d
    xorl    %r15d, %r15d
.srtf_scan:
    cmpl    proc_count(%rip), %r15d
    jge     .srtf_pick_done
    # not arrived yet?
    movl    proc_arrival(,%r15,4), %eax
    cmpl    %r12d, %eax
    jg      .srtf_scan_next
    # already finished?
    movl    proc_remaining(,%r15,4), %eax
    testl   %eax, %eax
    jz      .srtf_scan_next
    # smallest remaining wins; jge keeps the earlier candidate on a tie
    cmpl    %r14d, %eax
    jge     .srtf_scan_next
    movl    %eax, %r14d
    movl    %r15d, %r13d
.srtf_scan_next:
    incl    %r15d
    jmp     .srtf_scan

.srtf_pick_done:
    cmpl    $-1, %r13d
    jne     .srtf_run_one

    # nobody is ready right now. Maybe everyone is done, or maybe a
    # process is scheduled to arrive later -- check.
    call    any_remaining
    testl   %eax, %eax
    je      .srtf_done                  # truly nothing left
    movl    $'X', %edi
    call    emit_char                   # idle for one tick
    incl    %r12d
    jmp     .srtf_step

.srtf_run_one:
    movzbl  proc_id(,%r13,1), %edi
    call    emit_char
    decl    proc_remaining(,%r13,4)
    incl    %r12d
    jmp     .srtf_step

.srtf_done:
    ret


# PF - preemptive priority. Lower priority NUMBER means "more important".
# Tie-break order:
#   1) smallest priority
#   2) smallest remaining (effectively SRTF among equals)
#   3) earliest input position
#
# We keep two best-so-far values during the scan: %ebx for the best
# priority and %r14d for the best remaining within that priority.
run_pf:
    xorl    %r12d, %r12d

.pf_step:
    movl    $-1, %r13d
    movl    $0x7fffffff, %ebx
    movl    $0x7fffffff, %r14d
    xorl    %r15d, %r15d
.pf_scan:
    cmpl    proc_count(%rip), %r15d
    jge     .pf_pick_done

    # not arrived yet?
    movl    proc_arrival(,%r15,4), %eax
    cmpl    %r12d, %eax
    jg      .pf_scan_next
    # finished?
    movl    proc_remaining(,%r15,4), %eax
    testl   %eax, %eax
    jz      .pf_scan_next

    movl    proc_priority(,%r15,4), %ecx
    cmpl    %ebx, %ecx
    jl      .pf_take                    # strictly higher priority -> take
    jg      .pf_scan_next               # strictly worse -> skip
    # priorities equal -> compare remaining (SRTF tie break).
    cmpl    %r14d, %eax
    jge     .pf_scan_next               # not strictly smaller -> input order keeps the old one
.pf_take:
    movl    %ecx, %ebx
    movl    %eax, %r14d
    movl    %r15d, %r13d
.pf_scan_next:
    incl    %r15d
    jmp     .pf_scan

.pf_pick_done:
    cmpl    $-1, %r13d
    jne     .pf_run_one

    call    any_remaining
    testl   %eax, %eax
    je      .pf_done
    movl    $'X', %edi
    call    emit_char
    incl    %r12d
    jmp     .pf_step

.pf_run_one:
    movzbl  proc_id(,%r13,1), %edi
    call    emit_char
    decl    proc_remaining(,%r13,4)
    incl    %r12d
    jmp     .pf_step

.pf_done:
    ret


# RR - round robin. Everybody arrives at t=0 and goes into the queue in
# input order. Each turn we pop the front, run min(remaining, quantum)
# cycles, and either re-push (if there's still work) or pad with X up
# to the quantum boundary (the spec is explicit that the CPU does not
# switch mid-quantum).
#
# Live registers:
#   %r13d  current process index
#   %r14d  remaining BEFORE the run, then AFTER
#   %r15d  quantum  (loaded from memory once per turn)
#   %ebx   how many cycles we actually ran (saved across emit_n so we
#          can compute the X-padding length afterwards)
run_rr:
    # start with an empty queue, then push every index in input order
    movl    $0, rr_head(%rip)
    movl    $0, rr_tail(%rip)
    movl    $0, rr_size(%rip)
    xorl    %ecx, %ecx
.rr_init:
    cmpl    proc_count(%rip), %ecx
    jge     .rr_loop
    movl    %ecx, %edi
    pushq   %rcx                        # rr_push trashes ecx, save it
    call    rr_push
    popq    %rcx
    incl    %ecx
    jmp     .rr_init

.rr_loop:
    movl    rr_size(%rip), %eax
    testl   %eax, %eax
    jz      .rr_done                    # queue empty -> all done

    call    rr_pop                      # eax = popped index
    movl    %eax, %r13d

    movl    proc_remaining(,%r13,4), %r14d
    movl    quantum(%rip), %r15d
    # run = min(remaining, quantum)
    movl    %r14d, %ecx
    cmpl    %r15d, %ecx
    jle     1f
    movl    %r15d, %ecx
1:  movl    %ecx, %ebx                  # remember how many we actually ran

    movzbl  proc_id(,%r13,1), %edi
    call    emit_n                      # emit those cycles

    # update remaining after the run
    subl    %ebx, %r14d
    movl    %r14d, proc_remaining(,%r13,4)
    testl   %r14d, %r14d
    jnz     .rr_re_enqueue              # still has work -> back of queue

    # process is done within this slot. If it finished early we still
    # need to "burn" the rest of the quantum with X so the next process
    # only starts at the next quantum boundary.
    cmpl    %r15d, %ebx
    jge     .rr_loop                    # ran exactly the quantum -> no padding
    movl    %r15d, %ecx
    subl    %ebx, %ecx
    movl    $'X', %edi
    call    emit_n
    jmp     .rr_loop

.rr_re_enqueue:
    movl    %r13d, %edi
    call    rr_push
    jmp     .rr_loop

.rr_done:
    ret


# rr_push: enqueue the byte in %dil at rr_tail, bump rr_size, wrap if needed.
rr_push:
    movl    rr_tail(%rip), %eax
    leaq    rr_queue(%rip), %r10
    movb    %dil, (%r10,%rax,1)
    incl    %eax
    cmpl    $RR_CAP, %eax
    jl      1f
    xorl    %eax, %eax                  # wrap around
1:  movl    %eax, rr_tail(%rip)
    incl    rr_size(%rip)
    ret

# rr_pop: dequeue from rr_head, return the index in %eax.
rr_pop:
    movl    rr_head(%rip), %eax
    leaq    rr_queue(%rip), %r10
    movzbl  (%r10,%rax,1), %edx
    incl    %eax
    cmpl    $RR_CAP, %eax
    jl      1f
    xorl    %eax, %eax                  # wrap around
1:  movl    %eax, rr_head(%rip)
    decl    rr_size(%rip)
    movl    %edx, %eax                  # return value goes in eax
    ret
