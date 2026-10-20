.INCLUDE "M32DEF.INC"

; LCD 
.EQU LCD_DPRT = PORTA;Data port      
.EQU LCD_DDDR = DDRA;Data DDR
.EQU LCD_CPRT = PORTD;Command port
.EQU LCD_CDDR = DDRD;Command DDR
.EQU LCD_RS   = 6
.EQU LCD_EN   = 7          

; LED & Motor
.EQU LED_PRT  = PORTC
.EQU LED_DDR  = DDRC
.EQU LED_PIN  = 0

; Variables (Stored in Registers)
.DEF ENERGY = R19
.DEF MODE   = R20           ;Mode (0 = Single, 1 = Auto)
.DEF STEP_STATE = R22       ;stepper phase we are on (0,1,2,3)

; ==========================================
; INTERRUPT VECTOR TABLE
; ==========================================
.ORG 0x0000
    JMP MAIN                ; Reset Vector (Power On)

.ORG 0x0002
    JMP FIRE_WEAPON         ; INT0 Vector (Trigger Button on PD2)

.ORG 0x0004
    JMP CHANGE_MODE         ; INT1 Vector (Mode Button on PD3)


; ==========================================
; MAIN EXECUTION
; ==========================================
MAIN:
    ; 1. Stack Pointer
    LDI R21, HIGH(RAMEND)
    OUT SPH, R21           
    LDI R21, LOW(RAMEND)
    OUT SPL, R21

    ; 2. Configure I/O Ports
    LDI R21, 0B11111111
    OUT LCD_DDDR, R21       ; PORTA = Outputs (LCD)
    OUT LED_DDR, R21        ; PORTC = Outputs (LED)
    
    LDI R21, 0B11110011     ; 11110011 (PD2 and PD3 are Inputs for buttons, rest are outputs)
    OUT LCD_CDDR, R21
    
    ; 3. Enable Pull-Up Resistors for Buttons
    SBI PORTD, 2            ; Turn on internal pull-up for PD2 (Trigger)
    SBI PORTD, 3            ; Turn on internal pull-up for PD3 (Mode)

    ; 4. Set Initial Variables
    LDI ENERGY, 10          ; Start with 10 Energy
    LDI MODE, 0             ; Start in Single Mode (0)
    LDI STEP_STATE, 0B00000110    ; Start stepper sequence at binary 0110

    ; --- PRE-ENERGIZE MOTOR TO 0 DEGREES ---
    ; To make the first shot actually move 36 degrees, we must lock the motor at 0 degrees on boot.
    ; Binary 0110 maps to IN1(PD5) and IN3(PD1).
    SBI PORTD, 4            ; Energize Top Left
    SBI PORTD, 1            ; Energize Top Right

    ; 5. Configure Interrupts
    ; MCUCR: Set INT0 and INT1 to trigger on FALLING EDGE (when button is pressed to Ground)
    LDI R21, (1<<ISC11) | (0<<ISC10) | (1<<ISC01) | (0<<ISC00)
    OUT MCUCR, R21
    
    ; GICR: Enable INT0 and INT1 pins
    LDI R21, (1<<INT1) | (1<<INT0)
    OUT GICR, R21
    
    ; Turn on Global Interrupts (Master Switch)
    SEI                     

    ; 6. LCD Wakeup
    CALL DELAY_2ms          
    LDI R16, 0x38       
    CALL CMNDWRT            
    LDI R16, 0x0C           
    CALL CMNDWRT            
    LDI R16, 0x01           
    CALL CMNDWRT            
    CALL DELAY_2ms          
    LDI R16, 0x06           
    CALL CMNDWRT

    ; 7. Initial Screen Draw 
    CALL UPDATE_LCD

    ; 8. The Main Operational Loop
OPERATIONAL_LOOP:
    ; The CPU just spins here forever, waiting for a button interrupt!
    JMP OPERATIONAL_LOOP


; ==========================================
; INTERRUPT SERVICE ROUTINES (ISRs)
; ==========================================

FIRE_WEAPON:
    CALL DELAY_20ms         ; Debounce initial trigger press

FIRE_LOOP:
    CPI ENERGY, 0           ; Do we have ammo?
    BREQ FIRE_END           ; If energy is 0, jump to the end (Don't fire)

    ; 1. Turn on Fire Indicator LED
    SBI LED_PRT, LED_PIN

    ; 2. Step Motor
    CALL STEP_MOTOR         ; Triggers a 4-step magnetic sequence
	CALL DELAY_20ms
	CALL DELAY_20ms
	CALL DELAY_20ms
    ; 3. Decrease Energy
    DEC ENERGY

    ; 4. Update Screen
    CALL UPDATE_LCD

    ; 5. Turn off Fire Indicator LED
    CBI LED_PRT, LED_PIN

    ; 6. Mode Handling
    CPI MODE, 0             ; Check if we are in Single Mode
    BREQ WAIT_RELEASE       ; If Single, force wait for trigger release

    ; If we didn't branch, we are in Auto Mode!
    ; Check if the trigger (PD2) is STILL being held down to Ground (0)
    SBIC PIND, 2            ; Skip next instruction if PD2 is Clear (0 / Pressed)
    RJMP FIRE_END           ; If it is Set (1 / Released), end firing sequence
    RJMP FIRE_LOOP          ; If it is still 0, jump back and shoot again!

WAIT_RELEASE:
    SBIS PIND, 2            ; Skip next instruction if PD2 is Set (1 / Released)
    RJMP WAIT_RELEASE       ; Keep trapping CPU here while it is 0 (Pressed)
    CALL DELAY_20ms         ; Debounce the release

FIRE_END:
    RETI                    ; Return from Interrupt


CHANGE_MODE:
    CALL DELAY_20ms         ; Debounce button press

    ; Toggle the MODE register (0 <-> 1)
    CPI MODE, 0             
    BREQ SET_AUTO           
    LDI MODE, 0             ; Set to Single Mode
    RJMP END_TOGGLE         

SET_AUTO:
    LDI MODE, 1             ; Set to Auto Mode

END_TOGGLE:
    CALL UPDATE_LCD       ; Update the screen to show new mode
    
WAIT_MODE_RELEASE:
    SBIS PIND, 3            ; Wait for Mode button (PD3) to be released
    RJMP WAIT_MODE_RELEASE
    CALL DELAY_20ms         ; Debounce release

    RETI                    ; Return from Interrupt

; --- Single-Phase Stepper Motor State Machine (Textbook Method) ---
; Pins: IN1(PD5), IN2(PD4), IN3(PD1), IN4(PD0)
STEP_MOTOR:
    ; 1. Textbook Bit-Shift Logic (Rotate Right 4-bits)
    ; We shifted this math to the TOP so it calculates the NEXT shot (36 deg) before outputting it!
    LSR STEP_STATE          ; Shift all bits right by 1. Lowest bit falls into Carry.
    BRCC STEP_SKIP_ORI      ; If Carry is clear (0), skip the next line.
    ORI STEP_STATE, 0B00001000    ; If Carry is set (1), inject a 1 into the top bit (Bit 3)
STEP_SKIP_ORI:

    ; 2. Clear current motor pins
    CBI PORTD, 5 
    CBI PORTD, 4 
    CBI PORTD, 1 
    CBI PORTD, 0 

    ; 3. Map logical bits (3,2,1,0) to physical pins in a TRUE circular layout
    SBRC STEP_STATE, 3      ; Skip next instruction if Bit 3 is 0
    SBI PORTD, 5            ; Set IN2 (PD4) - Bottom Left
    
    SBRC STEP_STATE, 2      ; Skip next instruction if Bit 2 is 0
    SBI PORTD, 4            ; Set IN1 (PD5) - Top Left
    
    SBRC STEP_STATE, 1      ; Skip next instruction if Bit 1 is 0
    SBI PORTD, 1            ; Set IN3 (PD1) - Top Right
    
    SBRC STEP_STATE, 0      ; Skip next instruction if Bit 0 is 0
    SBI PORTD, 0            ; Set IN4 (PD0) - Bottom Right

    CALL DELAY_20ms         ; Give the magnetic gear time to physically move
    
    RET

; --- LCD Display Logic ---
UPDATE_LCD:
    ; Move cursor to top-left home position (0x80)
    LDI R16, 0x80
    CALL CMNDWRT

    ; Print "E:"
    LDI ZH, HIGH(STR_E << 1)
    LDI ZL, LOW(STR_E << 1)
    CALL PRINT_STRING

    ; Print ENERGY value
    CPI ENERGY, 10
    BREQ PRINT_TEN
    
    ; If < 10, print the single digit and a space
    MOV R16, ENERGY
    ORI R16, '0'          ; Convert binary to ASCII ('0' is 0x30)
    CALL DATAWRT
    LDI R16, ' '           ; ASCII for space (0x20)
    CALL DATAWRT            ; Trailing space erases the '0' when dropping from 10 to 9
    RJMP CHECK_MODE

PRINT_TEN:
    LDI R16, '1'
    CALL DATAWRT
    LDI R16, '0'
    CALL DATAWRT

CHECK_MODE:
    CPI MODE, 0
    BREQ PRINT_MODE_S

PRINT_MODE_A:
    LDI ZH, HIGH(STR_MODE_A << 1)
    LDI ZL, LOW(STR_MODE_A << 1)
    RJMP DO_PRINT_MODE

PRINT_MODE_S:
    LDI ZH, HIGH(STR_MODE_S << 1)
    LDI ZL, LOW(STR_MODE_S << 1)

DO_PRINT_MODE:
    CALL PRINT_STRING
    RET

; Helper subroutine to print a full string
PRINT_STRING:
    LPM R16, Z+
    CPI R16, 0
    BREQ PRINT_STRING_DONE
    CALL DATAWRT
    RJMP PRINT_STRING
PRINT_STRING_DONE:
    RET

; ==========================================
; HARDWARE SUBROUTINES
; ==========================================
CMNDWRT:
    OUT LCD_DPRT, R16       
    CBI LCD_CPRT, LCD_RS    
    SBI LCD_CPRT, LCD_EN    
    CALL SDELAY             
    CBI LCD_CPRT, LCD_EN    
    CALL DELAY_100us        
    RET

DATAWRT:
    OUT LCD_DPRT, R16       
    SBI LCD_CPRT, LCD_RS    
    SBI LCD_CPRT, LCD_EN    
    CALL SDELAY             
    CBI LCD_CPRT, LCD_EN    
    CALL DELAY_100us        
    RET

SDELAY:
    NOP
    NOP
    RET

DELAY_100us:
    PUSH R17
    LDI R17, 60
DR0:
    CALL SDELAY
    DEC R17
    BRNE DR0
    POP R17
    RET

DELAY_2ms:
    PUSH R17
    LDI R17, 20
LDR0:   
    CALL DELAY_100us
    DEC R17
    BRNE LDR0
    POP R17
    RET

DELAY_20ms:
    PUSH R17
    LDI R17, 10
LLDR0:   
    CALL DELAY_2ms
    DEC R17
    BRNE LLDR0
    POP R17
    RET

; ==========================================
; DATA SECTION (Flash Memory)
; ==========================================
STR_E: 
    .DB "E:", 0, 0          ; Extra 0 added to fix the padding warning!
STR_MODE_S: 
    .DB " MODE:S", 0
STR_MODE_A: 
    .DB " MODE:A", 0