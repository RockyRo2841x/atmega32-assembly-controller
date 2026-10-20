.INCLUDE "M32DEF.INC"

; LCD 
.EQU LCD_DPRT = PORTA       
.EQU LCD_DDDR = DDRA        
.EQU LCD_CPRT = PORTD       
.EQU LCD_CDDR = DDRD        
.EQU LCD_RS   = 6           ; Moved to PD6 based on new schematic
.EQU LCD_EN   = 7           

; LED,temp sensor
.EQU LED_PIN  = 4
.EQU TEMP_PIN = 7


; Variables (Stored in Registers)
.DEF ENERGY = R19           ; Dedicate R19 to hold the Energy value (0-10)
.DEF MODE   = R20           ; Dedicate R20 to hold Mode (0 = Single, 1 = Auto)
.DEF STEP_STATE = R22       ; Dedicate R22 to track which stepper phase we are on (0,1,2,3)
.DEF TEMP = R23             ;TEMP
.DEF TEMP_DATA = R24        ;RAW TEMP

;INTERRUPT VECTOR TABLE
.ORG 0x0000
    JMP MAIN                ; Reset Vector (Power On)

.ORG 0x0002
    JMP FIRE_WEAPON         ; INT0 Vector (Trigger Button on PD2)

.ORG 0x0004
    JMP CHANGE_MODE         ; INT1 Vector (Mode Button on PD3)

MAIN:
    ; 1. Stack Pointer
    LDI R21, HIGH(RAMEND)
    OUT SPH, R21           
    LDI R21, LOW(RAMEND)
    OUT SPL, R21

    ; 2. Configure I/O Ports
    LDI R21, 0B11111111
    OUT LCD_DDDR, R21       ; PORTA = Outputs (LCD)

	LDI R21, 0B01111111
    OUT DDRC, R21        ; PORTC

	SBI PORTC, 7         ; Turn on internal pull-up
    
    LDI R21, 0B11110011     ; 11110011 (PD2 and PD3 are Inputs for buttons, rest are outputs)
    OUT LCD_CDDR, R21       ; PORTD = Mixed I/O

    SBI PORTD, 2            ; Turn on internal pull-up for PD2 (Trigger)
    SBI PORTD, 3            ; Turn on internal pull-up for PD3 (Mode)

    ;Set Initial Variables
    LDI ENERGY, 10          ; Start with 10 Energy
    LDI MODE, 0             ; Start in Single Mode (0)
    LDI STEP_STATE, 0x06    ; Start stepper sequence at binary 0110 (Textbook Start)

    ;MOTOR TO 0 DEGREES
    SBI PORTD, 5
    SBI PORTD, 1

    ;Configure Interrupt Registers
    ; MCUCR: Set INT0 and INT1 to trigger on FALLING EDGE
    LDI R21, (1<<ISC11) | (0<<ISC10) | (1<<ISC01) | (0<<ISC00)
    OUT MCUCR, R21
    
    ; GICR: Enable INT0 and INT1 pins
    LDI R21, (1<<INT1) | (1<<INT0)
    OUT GICR, R21

    ;LCD INITIALISATION
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

; LEVEL 0: BOOT SEQUENCE
    LDI ZH, HIGH(MESSAGE << 1) 
    LDI ZL, LOW(MESSAGE << 1)
    LDI R17, 16

PRINT_BOOT_LOOP:
    LPM R16, Z+
    CPI R16, 0
    BREQ BOOT_DONE
    CALL DATAWRT
    
    DEC R17
    BREQ MOVE_TO_L2
    
    JMP PRINT_BOOT_LOOP

MOVE_TO_L2:
    LDI R16, 0xC0
    CALL CMNDWRT
    JMP PRINT_BOOT_LOOP

BOOT_DONE:
    CALL DELAY_3s           ; Wait for exactly 3 seconds
    
    LDI R16, 0x01           ; Load the "Clear Display" command
    CALL CMNDWRT            ; Send it to the screen
    CALL DELAY_2ms          ; Give the LCD time to physically wipe the glass

; LEVEL 1: HUD & OPERATIONAL START
    ; Turn on Global Interrupts
    SEI                     

    CALL UPDATE_LCD

OPERATIONAL_LOOP:
    JMP OPERATIONAL_LOOP

;INTERRUPT SERVICE ROUTINES (ISRs)

FIRE_WEAPON:
    CALL DELAY_20ms; Debounce initial trigger press

FIRE_LOOP:
    CPI ENERGY, 0
    BREQ FIRE_END;If energy is 0, jump to the end (Don't fire)

    SBI PORTC, LED_PIN

    ;STEPPER
    CALL STEP_MOTOR
	;DELAY SO THAT THE STEPPER CAN KEEPUP WITH THE LCD
    CALL DELAY_20ms
    CALL DELAY_20ms
    CALL DELAY_20ms

    DEC ENERGY

    CALL UPDATE_LCD

    CBI PORTC, LED_PIN

    ;Mode Handling
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
    LSR STEP_STATE          ; Shift all bits right by 1. Lowest bit falls into Carry.
    BRCC STEP_SKIP_ORI      ; If Carry is clear (0), skip the next line.
    ORI STEP_STATE, 0x08    ; If Carry is set (1), inject a 1 into the top bit (Bit 3)
STEP_SKIP_ORI:

    ; 2. Clear current motor pins
    CBI PORTD, 5 
    CBI PORTD, 4 
    CBI PORTD, 1 
    CBI PORTD, 0 

    ; 3. Map logical bits (3,2,1,0) to physical pins in a TRUE circular layout
    SBRC STEP_STATE, 3      ; Skip next instruction if Bit 3 is 0
    SBI PORTD, 4            ; Set IN2 (PD4) - Bottom Left
    
    SBRC STEP_STATE, 2      ; Skip next instruction if Bit 2 is 0
    SBI PORTD, 5            ; Set IN1 (PD5) - Top Left
    
    SBRC STEP_STATE, 1      ; Skip next instruction if Bit 1 is 0
    SBI PORTD, 1            ; Set IN3 (PD1) - Top Right
    
    SBRC STEP_STATE, 0      ; Skip next instruction if Bit 0 is 0
    SBI PORTD, 0            ; Set IN4 (PD0) - Bottom Right

    CALL DELAY_20ms         ; Give the magnetic gear time to physically move
    
    RET

;---------------------------------------LCD Display Logic-------------------------------------
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
    ORI R16, '0'            ; Convert binary to ASCII ('0' is 0x30)
    CALL DATAWRT
    LDI R16, ' '            ; ASCII for space (0x20)
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

;---------------------------------------TEMP SENSOR-------------------------------------------
HANDSHAKE:
    ;The Masters Call
    SBI DDRC, TEMP_PIN      ; Make pin an output
    CBI PORTC, TEMP_PIN     ; Output LOW (pull to ground)
    CALL DELAY_480us       ; Hold it down for 480us
    
    ;The Silence
    CBI DDRC, TEMP_PIN      ; Let go of the wire (make it an input)
                            ; The resistor pulls it HIGH immediately
    RCALL DELAY_60us        ; Wait 60us for the sensor to respond
    
    ;Master checks for Sensors reply
    IN TEMP, TEMP_PIN         ; Look at the wire. Is it HIGH or LOW?
    SBRC TEMP, TEMP_PIN       ; "Skip next instruction if the wire is LOW (0)"
    RJMP ERROR_NO_SENSOR    ; If wire was HIGH (1), jump to an error! 
                            ; (Because no sensor pulled it low)
    
    RCALL DELAY_420us       ; Wait out the rest of the 480us time slot 
                            ; so the sensor can finish its reply.
    RET

ERROR_NO_SENSOR:
	RJMP ERROR_NO_SENSOR

READ_TEMP:
    CALL HANDSHAKE
    LDI R16, 0xCC           ;Skip ROM (Address all devices)
    CALL WRITE_BYTE
    LDI R16, 0x44           ;Convert Temperature
    CALL WRITE_BYTE

    CALL DELAY_1s           ; Wait for DS18B20 ADC conversion to finish (requires ~750ms)

    CALL HANDSHAKE
    LDI R16, 0xCC           ;Skip ROM
    CALL WRITE_BYTE
    LDI R16, 0xBE           ;Read Scratchpad (Get Temp Data)
    CALL WRITE_BYTE

    CALL READ_BYTE          ; Read Byte 0: LSB
    MOV R25, R16 
    CALL READ_BYTE          ; Read Byte 1: MSB
    MOV R26, R16 

    
    MOV TEMP, R25           ; Store final integer temp in R23
    RET

WRITE_BYTE:
    LDI R17, 8              ; Loop 8 times for 8 bits
WB_LOOP:
    LSR R16                 ; Shift Least Significant Bit into Carry Flag
    BRCC WRITE_0
WRITE_1:
    SBI DDRC, TEMP_PIN      ; Output Mode
    CBI PORTC, TEMP_PIN     ; Pull LOW to start timeslot
    CALL DELAY_10us         ; Release within 15us for a '1'
    CBI DDRC, TEMP_PIN      ; Release bus
    CALL DELAY_60us         ; Wait for timeslot to finish
    RJMP WB_NEXT
WRITE_0:
    SBI DDRC, TEMP_PIN      ; Output Mode
    CBI PORTC, TEMP_PIN     ; Pull LOW to start timeslot
    CALL DELAY_60us         ; Hold LOW for entire 60us timeslot for a '0'
    CBI DDRC, TEMP_PIN      ; Release bus
    CALL DELAY_10us         ; Recovery time between bits
WB_NEXT:
    DEC R17
    BRNE WB_LOOP
    RET

READ_BYTE:
    LDI R17, 8              ; Loop 8 times for 8 bits
    CLR R16                 ; Clear target register
RB_LOOP:
    SBI DDRC, TEMP_PIN      ; Output Mode
    CBI PORTC, TEMP_PIN     ; Pull LOW to initiate read timeslot
    CALL SDELAY             ; Hold LOW for ~2us
    CBI DDRC, TEMP_PIN      ; Release bus so sensor can drive it
    CALL DELAY_10us         ; Wait near the end of the 15us sample window
    
    CLC                     ; Clear Carry Flag
    SBIC PINC, TEMP_PIN     ; Check the bus state
    SEC                     ; Set Carry Flag if bus is HIGH (1)
    
    ROR R16                 ; Rotate the Carry Flag bit into our Byte register
    CALL DELAY_60us         ; Wait for timeslot to finish
    DEC R17
    BRNE RB_LOOP
    RET


;DELAYS

SDELAY:
    NOP
    NOP
    RET

DELAY_10us:
    PUSH R17
    LDI R17, 6
_10us:
    CALL SDELAY
    DEC R17
    BRNE _10us
    POP R17
    RET

DELAY_60us:
    PUSH R17
    LDI R17, 6
_60: 
    CALL DELAY_10us
    DEC R17
    BRNE _60
    POP R17
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

DELAY_480us:
    PUSH R17
    LDI R17, 48
_480us:
    CALL DELAY_10us
    DEC R17
    BRNE _480us
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

DELAY_20ms:
    PUSH R17
    LDI R17, 10
_20ms:   
    CALL DELAY_2ms
    DEC R17
    BRNE _20ms
    POP R17
    RET

DELAY_1s:
    PUSH R17
    LDI R17, 50
_1s:   
    CALL DELAY_20ms
    DEC R17
    BRNE _1s
    POP R17
    RET

DELAY_3s:
    PUSH R17
    PUSH R18
    LDI R18, 15
L1_3s:
    LDI R17, 100
L2_3s:
    CALL DELAY_2ms
    DEC R17
    BRNE L2_3s              
    DEC R18
    BRNE L1_3s              
    POP R18
    POP R17
    RET

MESSAGE:
    .DB "ALTERRA OS BOOTING...", 0

STR_E: 
    .DB "E:", 0, 0          ; Extra 0 added to fix the padding warning!
STR_MODE_S: 
    .DB " MODE:S", 0
STR_MODE_A: 
    .DB " MODE:A", 0