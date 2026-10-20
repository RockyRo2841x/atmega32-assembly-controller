.INCLUDE "M32DEF.INC"

; --- ALIAS DICTIONARY ---
; LCD 
.EQU LCD_DPRT = PORTA       
.EQU LCD_DDDR = DDRA        
.EQU LCD_CPRT = PORTD       
.EQU LCD_CDDR = DDRD        
.EQU LCD_RS   = 6           
.EQU LCD_EN   = 7           

; LED, Sensors
.EQU LED_PIN  = 4
.EQU TEMP_PIN = 7
.EQU TRIG_PIN = 6
.EQU ECHO_PIN = 5

; Variables (Stored in Registers)
.DEF ENERGY = R19           ; Dedicate R19 to hold the Energy value (0-10)
.DEF MODE   = R20           ; Dedicate R20 to hold Mode (0 = Single, 1 = Auto)
.DEF STEP_STATE = R22       ; Dedicate R22 to track which stepper phase we are on (0,1,2,3)
.DEF TEMP = r23             ; Final Temperature
.DEF TEMP_DATA = r24        ; RAW TEMP

;INTERRUPT VECTOR TABLE
.ORG 0x0000
    JMP MAIN                ; Reset Vector (Power On)

.ORG 0x0002
    JMP FIRE_WEAPON         ; INT0 Vector (Trigger Button on PD2)

.ORG 0x0004
    JMP CHANGE_MODE         ; INT1 Vector (Mode Button on PD3)

MAIN:
    LDI R21, HIGH(RAMEND)
    OUT SPH, R21           
    LDI R21, LOW(RAMEND)
    OUT SPL, R21

    LDI R21, 0B11111111
    OUT LCD_DDDR, R21       ; PORTA = Outputs (LCD)

    ; PC7 (Temp) & PC5 (Echo) as Inputs. PC6 (Trig) & PC4 (LED) as Outputs.
    LDI R21, 0B01011111
    OUT DDRC, R21        

    SBI PORTC, 7         ; Turn on internal pull-up for Temp sensor
    
    LDI R21, 0B11110011     ; 11110011 (PD2 and PD3 are Inputs for buttons, rest are outputs)
    OUT LCD_CDDR, R21       ; PORTD = Mixed I/O

    SBI PORTD, 2            ; Turn on internal pull-up for PD2 (Trigger)
    SBI PORTD, 3            ; Turn on internal pull-up for PD3 (Mode)

    LDI ENERGY, 10          ; Start with 10 Energy
    LDI MODE, 0             ; Start in Single Mode (0)
    LDI STEP_STATE, 0x06    ; Start stepper sequence at binary 0110 (Textbook Start)

    ;MOTOR TO 0 DEGREES
    SBI PORTD, 5
    SBI PORTD, 1

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
    CALL DELAY_3s           
    LDI R16, 0x01           
    CALL CMNDWRT            
    CALL DELAY_2ms          

; LEVEL 1 & 2: HUD & OPERATIONAL START
    SEI                     
    CALL UPDATE_LCD

OPERATIONAL_LOOP:
    ; Read the Environment!
    CALL READ_TEMP
    CALL READ_DIST
    CALL UPDATE_LCD_L2
    JMP OPERATIONAL_LOOP

; ==========================================
; INTERRUPT SERVICE ROUTINES (ISRs)
; ==========================================

FIRE_WEAPON:
    CALL DELAY_20ms

FIRE_LOOP:
    CPI ENERGY, 0
    BREQ FIRE_END

    SBI PORTC, LED_PIN

    CALL STEP_MOTOR
    CALL DELAY_20ms
    CALL DELAY_20ms
    CALL DELAY_20ms

    DEC ENERGY
    CALL UPDATE_LCD
    CBI PORTC, LED_PIN

    CPI MODE, 0             
    BREQ WAIT_RELEASE       

    SBIC PIND, 2            
    RJMP FIRE_END           
    RJMP FIRE_LOOP          

WAIT_RELEASE:
    SBIS PIND, 2            
    RJMP WAIT_RELEASE       
    CALL DELAY_20ms         

FIRE_END:
    RETI                    


CHANGE_MODE:
    CALL DELAY_20ms         
    CPI MODE, 0             
    BREQ SET_AUTO           
    LDI MODE, 0             
    RJMP END_TOGGLE         

SET_AUTO:
    LDI MODE, 1             

END_TOGGLE:
    CALL UPDATE_LCD       
    
WAIT_MODE_RELEASE:
    SBIS PIND, 3            
    RJMP WAIT_MODE_RELEASE
    CALL DELAY_20ms         

    RETI                    

; ==========================================
; HARDWARE SUBROUTINES
; ==========================================
STEP_MOTOR:
    LSR STEP_STATE          
    BRCC STEP_SKIP_ORI      
    ORI STEP_STATE, 0x08    
STEP_SKIP_ORI:
    CBI PORTD, 5 
    CBI PORTD, 4 
    CBI PORTD, 1 
    CBI PORTD, 0 
    SBRC STEP_STATE, 3      
    SBI PORTD, 4            
    SBRC STEP_STATE, 2      
    SBI PORTD, 5            
    SBRC STEP_STATE, 1      
    SBI PORTD, 1            
    SBRC STEP_STATE, 0      
    SBI PORTD, 0            
    CALL DELAY_20ms         
    RET


; --- LEVEL 2: SENSOR READING SUBROUTINES ---

READ_TEMP:
    CALL HANDSHAKE
    LDI R16, 0xCC           ; Skip ROM
    CALL WRITE_BYTE
    LDI R16, 0x44           ; Convert Temperature
    CALL WRITE_BYTE

    CALL DELAY_1s           ; Wait for DS18B20 conversion to finish

    CALL HANDSHAKE
    LDI R16, 0xCC           ; Skip ROM
    CALL WRITE_BYTE
    LDI R16, 0xBE           ; Read Scratchpad
    CALL WRITE_BYTE

    CALL READ_BYTE          ; Read LSB
    MOV R24, R16 
    CALL READ_BYTE          ; Read MSB
    MOV R25, R16 

    ; The DS18B20 returns temp in 1/16th degrees. 
    ; Shift right 4 times to drop the fraction and get pure Celsius.
    LSR R25
    ROR R24
    LSR R25
    ROR R24
    LSR R25
    ROR R24
    LSR R25
    ROR R24
    MOV TEMP, R24           ; Store final integer temp in R23
    RET

READ_DIST:
    ; 1. Calculate Temp-Compensated Divisor: Divisor = 60 - (Temp / 10)
    MOV R16, TEMP
    CLR R17
CALC_DIV_LOOP:
    SUBI R16, 10
    BRCS CALC_DIV_DONE
    INC R17                 ; R17 now holds (Temp/10)
    RJMP CALC_DIV_LOOP
CALC_DIV_DONE:
    LDI R27, 60
    SUB R27, R17            ; R27 is our dynamic divisor!

    ; 2. Fire Ultrasonic Pulse
    SBI DDRC, TRIG_PIN 
    SBI PORTC, TRIG_PIN
    CALL DELAY_10us
    CBI PORTC, TRIG_PIN

    ; 3. Setup Timer 1
    LDI R16, 0x00
    OUT TCNT1H, R16
    OUT TCNT1L, R16

WAIT_ECHO_HIGH:
    SBIS PINC, ECHO_PIN     ; Wait for Echo to go HIGH
    RJMP WAIT_ECHO_HIGH

    ; Start Timer 1 (Prescaler 8 for 8MHz clock = 1 tick per microsecond)
    LDI R16, 0x02
    OUT TCCR1B, R16

WAIT_ECHO_LOW:
    SBIC PINC, ECHO_PIN     ; Wait for Echo to go LOW
    RJMP WAIT_ECHO_LOW

    ; Stop Timer 1
    LDI R16, 0x00
    OUT TCCR1B, R16

    ; 4. Calculate Distance
    IN R24, TCNT1L
    IN R25, TCNT1H
    CLR R26                 ; R26 will be the Distance counter (cm)
DIST_DIV_LOOP:
    CPI R26, 255            ; Prevent overflow beyond 255cm
    BREQ DIST_DIV_DONE
    SUB R24, R27            ; Subtract our Temp-Compensated Divisor!
    SBCI R25, 0
    BRCS DIST_DIV_DONE
    INC R26
    RJMP DIST_DIV_LOOP
DIST_DIV_DONE:
    RET


; --- 1-Wire DS18B20 Protocol ---
HANDSHAKE:
    SBI DDRC, TEMP_PIN      ; Pin as output
    CBI PORTC, TEMP_PIN     ; Pull to ground
    CALL DELAY_480us       
    
    CBI DDRC, TEMP_PIN      ; Release pin
    RCALL DELAY_60us        
    
    IN TEMP_DATA, PINC      ; Read response
    SBRC TEMP_DATA, TEMP_PIN
    RJMP ERROR_NO_SENSOR    
    CALL DELAY_420us       
    RET
ERROR_NO_SENSOR:
    RJMP ERROR_NO_SENSOR

WRITE_BYTE:
    LDI R17, 8
WB_LOOP:
    LSR R16
    BRCC WRITE_0
WRITE_1:
    SBI DDRC, TEMP_PIN
    CBI PORTC, TEMP_PIN
    CALL DELAY_10us
    CBI DDRC, TEMP_PIN      ; Release
    CALL DELAY_60us
    RJMP WB_NEXT
WRITE_0:
    SBI DDRC, TEMP_PIN
    CBI PORTC, TEMP_PIN
    CALL DELAY_60us
    CBI DDRC, TEMP_PIN      ; Release
    CALL DELAY_10us
WB_NEXT:
    DEC R17
    BRNE WB_LOOP
    RET

READ_BYTE:
    LDI R17, 8
    CLR R16
RB_LOOP:
    SBI DDRC, TEMP_PIN
    CBI PORTC, TEMP_PIN
    CALL SDELAY             ; ~2us pulse
    CBI DDRC, TEMP_PIN      ; Release
    CALL DELAY_10us         ; Wait for sensor to assert line
    CLC
    SBIC PINC, TEMP_PIN
    SEC                     ; Set carry if line is High
    ROR R16                 ; Shift bit into byte
    CALL DELAY_60us         ; Complete timeslot
    DEC R17
    BRNE RB_LOOP
    RET


; --- LCD Display Logic ---
UPDATE_LCD:
    LDI R16, 0x80
    CALL CMNDWRT
    LDI ZH, HIGH(STR_E << 1)
    LDI ZL, LOW(STR_E << 1)
    CALL PRINT_STRING
    CPI ENERGY, 10
    BREQ PRINT_TEN
    MOV R16, ENERGY
    ORI R16, '0'            
    CALL DATAWRT
    LDI R16, ' '            
    CALL DATAWRT            
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

UPDATE_LCD_L2:
    LDI R16, 0xC0           ; Move to Line 2
    CALL CMNDWRT

    LDI ZH, HIGH(STR_DIST << 1)
    LDI ZL, LOW(STR_DIST << 1)
    CALL PRINT_STRING

    MOV R16, R26            ; Load calculated distance
    CALL PRINT_3_DIGIT

    LDI ZH, HIGH(STR_TEMP << 1)
    LDI ZL, LOW(STR_TEMP << 1)
    CALL PRINT_STRING

    MOV R16, TEMP           ; Load calculated temperature
    CALL PRINT_2_DIGIT

    LDI R16, 'C'
    CALL DATAWRT
    RET


; --- Number Formatting ---
PRINT_3_DIGIT:
    CLR R17
H_LOOP:
    SUBI R16, 100
    BRCS H_DONE
    INC R17
    RJMP H_LOOP
H_DONE:
    SUBI R16, -100          ; Add 100 back
    PUSH R16                ; Save remainder
    MOV R16, R17
    ORI R16, '0'
    CALL DATAWRT            ; Print Hundreds
    POP R16
PRINT_2_DIGIT:
    CLR R17
T_LOOP:
    SUBI R16, 10
    BRCS T_DONE
    INC R17
    RJMP T_LOOP
T_DONE:
    SUBI R16, -10           ; Add 10 back
    PUSH R16
    MOV R16, R17
    ORI R16, '0'
    CALL DATAWRT            ; Print Tens
    POP R16
    ORI R16, '0'
    CALL DATAWRT            ; Print Ones
    RET

PRINT_STRING:
    LPM R16, Z+
    CPI R16, 0
    BREQ PRINT_STRING_DONE
    CALL DATAWRT
    RJMP PRINT_STRING
PRINT_STRING_DONE:
    RET

; ==========================================
; DELAYS & IO
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

	DELAY_420us:
    PUSH R17
    LDI R17, 42
_420us:
    CALL DELAY_10us
    DEC R17
    BRNE _420us
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
    LDI R17, 3
_3s:
    CALL DELAY_1s
    DEC R17
    BRNE _3s              
    POP R17
    RET

; ==========================================
; DATA SECTION (Flash Memory)
; ==========================================
MESSAGE:
    .DB "ALTERRA OS BOOTING...", 0

STR_E: 
    .DB "E:", 0, 0          
STR_MODE_S: 
    .DB " MODE:S", 0
STR_MODE_A: 
    .DB " MODE:A", 0
STR_DIST:
    .DB "DIST:", 0
STR_TEMP:
    .DB " TEMP:", 0, 0