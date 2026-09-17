@ P21 APP_MAIN icon-LCD host-push patch — injected Thumb (ARMv6-M / Cortex-M0).
@ Assembled position-independently: every firmware/RAM address is a literal-pool
@ constant, every internal branch is PC-relative, so the raw .text bytes drop in
@ at VM 0xbf000 with NO relocation. my_dispatch MUST be at offset 0 (the hook
@ jump-table word points at it).
@
@ Reached from the 0x031b BR-SET label dispatcher: the first-char jump table slot
@ for 'P' (0xb0e90) is repointed here. Entered by `mov pc,r3` with the dispatcher
@ frame live: r7=task obj, r9=BR payload ptr, r11=label halfword, sp=dispatcher
@ frame. Payload layout (r9): [0:2]=cmd 0x031b, [4:12]=8-byte label, [0xc:]=body.
@
@ Wire (host `data` arg to br_send, id=0x031b, type=5):
@   data[0:2]=00 00  data[2:6]="PLCD"  data[6:10]=00 00 00 00  data[10:]=body
@ Body ops:  'B' x y w h        begin (u8 each)
@            'D' offLo offHi len pix[len]   data (offset u16 LE, len<=37)
@            'S'                show (draw buffered rect)
@            'Q'                query (data reply: 8-byte magic "P21LCDv1")

    .syntax unified
    .cpu cortex-m0
    .thumb
    .section .text
    .global _start
_start:

@ ---- state block @ 0x20001200 (gapA, provably unreferenced) ----
@  +0x00 u32 magic (0x42313250 "P21B" once a Begin succeeds)
@  +0x04 u32 framebuffer ptr (allocator, capacity 7200)
@  +0x08 u16 w   +0x0a u16 h   +0x0c u8 x   +0x0d u8 y
    .equ STATE,   0x20001200
    .equ MAGIC,   0x42313250
    .equ DISPPTR, 0x20002170      @ *DISPPTR = icon display object
    @ blx/bx targets carry bit0=1 (Thumb state); even targets HardFault on M0.
    .equ DRAW,    0x69685         @ Icon_draw(this,x,y,w,h,pix565)
    .equ MEMCPY,  0xa8521
    .equ MALLOC,  0x84c41         @ zeroing pool alloc (framework frees via 0x84ce4)
    .equ DEFRPLY, 0x64b0f         @ 0x031b common reply tail (Thumb, +1)
    .equ BUFCAP,  7200            @ 60*60*2
    .equ MAXWH,   3600            @ BUFCAP/2

@ =====================================================================
@ my_dispatch — offset 0. Confirm label "PLCD" then hand off, else fall
@ through to the stock default reply so non-"PLCD" 'P' labels are unchanged.
@ =====================================================================
my_dispatch:
    mov     r3, r9                @ r9 is a high reg; v6-M ldrh needs a low base
    ldrh    r0, [r3, #4]          @ label[0:2]  ("PL" = 0x4c50)
    ldr     r1, =0x00004c50
    cmp     r0, r1
    bne     .Ldefault
    ldrh    r0, [r3, #6]          @ label[2:4]  ("CD" = 0x4443)
    ldr     r1, =0x00004443
    cmp     r0, r1
    bne     .Ldefault
    mov     r1, r9
    adds    r1, #0xc              @ r1 = body
    add     r2, sp, #0x1c         @ r2 = &sp[0x1c]  (data-return ptr slot)
    movs    r3, #0x1e
    add     r3, sp                @ sp+0x1e
    adds    r3, #0x10             @ r3 = sp+0x2e    (data-return len slot)
    bl      my_handler
    add     r3, sp, #0x30
    strh    r0, [r3, #4]          @ status -> sp+0x34
.Ldefault:
    ldr     r3, =DEFRPLY
    bx      r3

@ =====================================================================
@ my_handler(r1=body, r2=&datap, r3=&count_u16) -> r0 status (0 ok, 1 fail)
@ =====================================================================
    .align 2
my_handler:
    push    {r4, r5, r6, r7, lr}
    mov     r4, r1                @ r4 = body
    mov     r5, r2                @ r5 = &datap
    mov     r6, r3                @ r6 = &count
    ldr     r7, =STATE            @ r7 = state
    ldrb    r0, [r4, #0]          @ op
    cmp     r0, #0x42             @ 'B'
    beq     op_begin
    cmp     r0, #0x44             @ 'D'
    beq     op_data
    cmp     r0, #0x53             @ 'S'
    beq     op_show
    cmp     r0, #0x51             @ 'Q'
    beq     op_query
    movs    r0, #1
h_ret:
    pop     {r4, r5, r6, r7, pc}

@ ---- Begin: validate rect, ensure buffer, latch geometry + magic ----
op_begin:
    ldrb    r0, [r4, #3]          @ w
    ldrb    r1, [r4, #4]          @ h
    cmp     r0, #0
    beq     begin_fail
    cmp     r1, #0
    beq     begin_fail
    movs    r2, r0
    muls    r2, r1, r2            @ r2 = w*h
    ldr     r3, =MAXWH
    cmp     r2, r3
    bhi     begin_fail            @ w*h*2 > BUFCAP
    ldrb    r2, [r4, #1]          @ x
    adds    r2, r2, r0            @ x+w
    cmp     r2, #160
    bhi     begin_fail
    ldrb    r2, [r4, #2]          @ y
    adds    r2, r2, r1            @ y+h
    cmp     r2, #82
    bhi     begin_fail
    ldr     r2, [r7, #4]          @ framebuffer ptr
    cmp     r2, #0
    bne     begin_finish
    ldr     r0, =BUFCAP
    ldr     r3, =MALLOC
    blx     r3
    cmp     r0, #0
    beq     begin_fail
    str     r0, [r7, #4]
begin_finish:
    ldrb    r0, [r4, #3]
    strh    r0, [r7, #8]          @ w
    ldrb    r0, [r4, #4]
    strh    r0, [r7, #0xa]        @ h
    ldrb    r0, [r4, #1]
    strb    r0, [r7, #0xc]        @ x
    ldrb    r0, [r4, #2]
    strb    r0, [r7, #0xd]        @ y
    ldr     r0, =MAGIC
    str     r0, [r7, #0]
    movs    r0, #0
    b       h_ret
begin_fail:
    movs    r0, #1
    b       h_ret

@ ---- Data: bounded copy of pixel bytes into framebuffer ----
op_data:
    ldr     r0, [r7, #0]
    ldr     r1, =MAGIC
    cmp     r0, r1
    bne     data_fail             @ no successful Begin yet
    ldr     r0, [r7, #4]          @ framebuffer
    cmp     r0, #0
    beq     data_fail
    ldrb    r1, [r4, #1]          @ off lo
    ldrb    r2, [r4, #2]          @ off hi
    lsls    r2, r2, #8
    orrs    r1, r2                @ r1 = offset
    ldrb    r2, [r4, #3]          @ len
    cmp     r2, #0
    beq     data_fail
    cmp     r2, #37
    bhi     data_fail
    ldrh    r3, [r7, #8]          @ w
    push    {r0, r1, r2}
    ldrh    r0, [r7, #0xa]        @ h
    muls    r3, r0, r3            @ w*h
    lsls    r3, r3, #1            @ w*h*2
    adds    r0, r1, r2            @ offset+len
    cmp     r0, r3
    bhi     data_fail_pop
    pop     {r0, r1, r2}          @ buf, offset, len
    adds    r0, r0, r1            @ dst = buf + offset
    adds    r1, r4, #4            @ src = body + 4
    ldr     r3, =MEMCPY
    blx     r3
    movs    r0, #0
    b       h_ret
data_fail_pop:
    pop     {r0, r1, r2}
data_fail:
    movs    r0, #1
    b       h_ret

@ ---- Show: draw buffered rect straight to the panel (BR-task context) ----
op_show:
    ldr     r0, [r7, #0]
    ldr     r2, =MAGIC
    cmp     r0, r2
    bne     show_fail
    ldr     r1, [r7, #4]          @ framebuffer
    cmp     r1, #0
    beq     show_fail
    ldr     r0, =DISPPTR
    ldr     r0, [r0]              @ display object
    cmp     r0, #0
    beq     show_fail
    ldrh    r2, [r7, #0xa]        @ h
    sub     sp, #8
    str     r2, [sp, #0]          @ arg5 = h
    str     r1, [sp, #4]          @ arg6 = framebuffer
    ldrb    r1, [r7, #0xc]        @ x
    ldrb    r2, [r7, #0xd]        @ y
    ldrh    r3, [r7, #8]          @ w
    ldr     r5, =DRAW
    blx     r5
    add     sp, #8
    movs    r0, #0
    b       h_ret
show_fail:
    movs    r0, #1
    b       h_ret

@ ---- Query: 8-byte magic data reply ("P21LCDv1") for build detection ----
op_query:
    movs    r0, #8
    ldr     r3, =MALLOC
    blx     r3
    cmp     r0, #0
    beq     query_fail
    ldr     r1, =0x4c313250       @ "P21L"
    str     r1, [r0, #0]
    ldr     r1, =0x31764443       @ "CDv1"
    str     r1, [r0, #4]
    str     r0, [r5]              @ *datap = ptr
    movs    r1, #8
    strh    r1, [r6]              @ *count = 8
    movs    r0, #0
    b       h_ret
query_fail:
    movs    r0, #1
    b       h_ret

    .align 2
    .ltorg
    .global _end
_end:
