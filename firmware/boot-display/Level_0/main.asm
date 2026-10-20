.INCLUDE "M32DEF.INC"

.EQU LCD_DPRT = PORTA
.EQU LCD_DDDR = DDRA
.EQU LCD_DPIN = PINA
.EQU LCD_CPRT = PORTD
.EQU LCD_CDDR = DDRD
.EQU LCD_CPIN = PIND
.EQU LCD_RS   = 5
.EQU LCD_EN   = 7           ; LCD EN Pin (PD7)

.ORG 0x0000
    JMP MAIN

MESSAGE:
    .DB "ALTERRA OS BOOTING...", 0

MAIN:
	;intialising stack pointer
    LDI R21, HIGH(RAMEND)
    OUT SPH, R21           
    LDI R21, LOW(RAMEND)
    OUT SPL, R21

    ;Configuring I/O Ports
    LDI R21, 0B11111111     ; 0xFF 11111111
    OUT LCD_DDDR, R21       ; LCD data port is output
    OUT LCD_CDDR, R21       ; LCD command port is output
    CBI LCD_CPRT, LCD_EN    ; LCD_EN = 0

    ; Wake-up Sequence
    CALL DELAY_2ms          ; wait for power on
    LDI R16, 0x38           ; init LCD 2 lines, 5x7 matrix
    CALL CMNDWRT            ; call command function
    CALL DELAY_2ms          ; wait 2 ms
    LDI R16, 0x0C           ; display on, cursor OFF
    CALL CMNDWRT            
    LDI R16, 0x01           ; clear LCD
    CALL CMNDWRT            
    CALL DELAY_2ms          ; wait 2 ms
    LDI R16, 0x06           ; shift cursor right
    CALL CMNDWRT            

; Fetch String from Memory and Print
    LDI ZH, HIGH(MESSAGE << 1) 
    LDI ZL, LOW(MESSAGE << 1)
    
    LDI R17, 16

PRINT_LOOP:
    LPM R16, Z+
    CPI R16, 0
    BREQ BOOT_DONE
    CALL DATAWRT
    
    DEC R17
    BREQ MOVE_TO_L2
    
    JMP PRINT_LOOP

MOVE_TO_L2:
    LDI R16, 0xC0
    CALL CMNDWRT
    JMP PRINT_LOOP

BOOT_DONE:
    CALL DELAY_3s
    
    LDI R16, 0x01
    CALL CMNDWRT
    CALL DELAY_2ms

HERE: 
    JMP HERE

CMNDWRT:
    OUT LCD_DPRT, R16
    CBI LCD_CPRT, LCD_RS    ; RS = 0 for command
    SBI LCD_CPRT, LCD_EN    ; EN = 1
    CALL SDELAY             ; make a wide EN pulse
    CBI LCD_CPRT, LCD_EN    ; EN = 0 for H-to-L pulse
    CALL DELAY_100us        ; wait 100 us
    RET

DATAWRT:
    OUT LCD_DPRT, R16       ; LCD data port = R16
    SBI LCD_CPRT, LCD_RS    ; RS = 1 for data
    SBI LCD_CPRT, LCD_EN    ; EN = 1
    CALL SDELAY             ; make a wide EN pulse
    CBI LCD_CPRT, LCD_EN    ; EN = 0 for H-to-L pulse
    CALL DELAY_100us        ; wait 100 us
    RET

SDELAY: 
    NOP
    NOP
    RET

DELAY_100us:
    PUSH R17
    LDI R17, 60
_100us:    
    CALL SDELAY
    DEC R17
    BRNE _100us
    POP R17
    RET

DELAY_2ms:
    PUSH R17
    LDI R17, 20
_2ms:   
    CALL DELAY_100us
    DEC R17
    BRNE _2ms
    POP R17
    RET

;Loops DELAY_2ms 1,500 times (15*100*2ms = 3000ms = 3s)
DELAY_3s:
    PUSH R17
    PUSH R18
    LDI R18, 15
L1_3s:
    LDI R17, 100
L2_3s:
    CALL DELAY_2ms
    DEC R17
    BRNE L2_3s;innerLoop 100 times
    DEC R18
    BRNE L1_3s;outerLoop 15 times
    POP R18
    POP R17
    RET