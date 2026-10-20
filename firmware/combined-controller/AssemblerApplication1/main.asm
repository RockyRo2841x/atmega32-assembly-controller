	.INCLUDE "M32DEF.INC"

	;LCD 
	.EQU LCD_DPRT = PORTA       
	.EQU LCD_DDDR = DDRA                   
	.EQU LCD_CPRT = PORTD       
	.EQU LCD_CDDR = DDRD        
	.EQU LCD_RS   = 6
	.EQU LCD_EN   = 7           

	;LED, Sensors
	.EQU LED_PIN  = 4
	.EQU TEMP_PIN = 7
	.EQU TRIG_PIN = 6
	.EQU ECHO_PIN = 5
	.EQU BUZZ_PIN = 3
	.EQU ILED_PIN = 2
	;MCP3008
	.EQU MOSI = 5
	.EQU MISO = 6
	.EQU SCK  = 7
	.EQU CS   = 4

	;Variables
	.DEF ENERGY = R19
	.DEF MODE   = R20
	.DEF STEP_STATE = R22       ;Dedicate R22 to track which stepper phase we are on (0,1,2,3)
	.DEF TEMP = R23             ;Final Temperature
	.DEF TEMP_DATA = R24        ;RAW TEMP
	.DEF SENSOR_TIMER = R25

	;Dedicated a register for System Flags so ISRs dont block the CPU
	;Bit0 = Fire Weapon Requested
	;Bit1 = Change Mode Requested
	;Bit2 = Reload Requested
	.DEF FLAGS = R21

	;INTERRUPT VECTOR TABLE
	.ORG 0x0000
		JMP MAIN			;Reset Vector (Power on)

	.ORG 0x0002
		JMP FIRE_WEAPON		;INT0 Vector (Trigger Button)

	.ORG 0x0004
		JMP CHANGE_MODE		;INT1 Vector(Mode Button)

	.ORG 0x0006
		JMP RELOAD			;INT1 Vector(Reload button)

	MAIN:
		; Stack Pointer
		LDI R21, HIGH(RAMEND)
		OUT SPH, R21           
		LDI R21, LOW(RAMEND)
		OUT SPL, R21

		;Configure I/O Ports
		LDI R21, 0B11111111
		OUT LCD_DDDR, R21		;PORTA = Outputs

		LDI R21, 0B11111011		;PORTB PIN PB2 = Reload
		OUT DDRB, R21			
		SBI PORTB, 2			;INTERNAL PULL UP FOR RELOAD

		;Temp,Echo are INPUTS, Trig,LED are OUTPUTS
		LDI R21, 0B01011111
		OUT DDRC, R21

		SBI PORTC, 7				;Turn on internal pull up for Temp sensor
    
		LDI R21, 0B11110011			;Inputs for buttons
		OUT DDRD, R21

		SBI PORTD, 2				;Turn on internal pull up for Trigger
		SBI PORTD, 3				;Turn on internal pull up for Mode

		;Set Initial Variables
		LDI ENERGY, 10
		LDI MODE, 0
		LDI STEP_STATE, 0x06		;Start stepper sequence at binary 0110
    
		;Initialize the new FLAGS register to 0
		CLR FLAGS               

		;MOTOR TO 0 DEGREES
		SBI PORTD, 5
		SBI PORTD, 1

		;Configure Interrupt Registers
		LDI R21, (1<<ISC11) | (0<<ISC10) | (1<<ISC01) | (0<<ISC00) ;configuring Interupts to trigger on the rising edge
		OUT MCUCR, R21

		LDI R21, (0<<ISC2) 
		OUT MCUCSR, R21
		
		LDI R21, (1<<INT1) | (1<<INT0) | (1<<INT2);Enabling INT1 and INT0
		OUT GICR, R21

;======================================================LEVEL0=======================================================
		;Initialising LCD
		CALL LCD_INIT

		LDI ZH, HIGH(MESSAGE << 1) 
		LDI ZL, LOW(MESSAGE << 1)
		LDI R17, 16;Character counter so we can go to the next line after 16 characters

	PRINT_BOOT_LOOP:
		LPM R16, Z+
		CPI R16, 0
		BREQ BOOT_DONE
		CALL DATAWRT
        
		DEC R17
		BREQ MOVE_TO_L2; Branch to MOVE_TO_L2 if R17=0
		
		JMP PRINT_BOOT_LOOP

	MOVE_TO_L2:
		LDI R16, 0xC0;command to go to line 2 of the LCD
		CALL CMNDWRT
		JMP PRINT_BOOT_LOOP

	BOOT_DONE:
		CALL DELAY_3s			; Wait for exactly 3 seconds
		
		LDI R16, 0x01			; Clear Display command
		CALL CMNDWRT
		CALL DELAY_2ms			;Give the LCD time to physically wipe the glass


	;=====================================================LEVEL 1======================================================

		SEI;Turn on Global Interrupts

		CALL Level1_LCD;Updates LCD to Draw Ammo and Mode on Line 1

	OPERATIONAL_LOOP:
        ;CHECK RELOAD
        SBRS FLAGS, 2           ;Check if bit 2 is set
        RJMP CHECK_MODE_FLAG    ;If not set JMP
        CBR FLAGS, (1<<2)       ;Clear flag
        CALL DO_RELOAD

    CHECK_MODE_FLAG:
        ;CHECK MODE (Bit 1)
        SBRS FLAGS, 1           ;Check if bit 1 is set
        RJMP CHECK_FIRE_FLAG    ;If not set JMP
        CBR FLAGS, (1<<1)       ;Clear flag
        CALL DO_CHANGE_MODE

    CHECK_FIRE_FLAG:
        ;CHECK MANUAL FIRE (Bit 0)
        SBRS FLAGS, 0           ;Check if bit 0 is set
        RJMP CHECK_AUTO_MODE    ;If not set JMP
        CBR FLAGS, (1<<0)       ;Clear flag
        CALL DO_FIRE_WEAPON

    CHECK_AUTO_MODE:
        ;CHECK AUTO FIRE
        CPI MODE, 1             ;Checking if we are in Auto Mode
        BRNE DO_SENSORS         ;if Not, Jump to sensors
        SBIC PIND, 2            ;is Trigger held(0 = held)
        RJMP DO_SENSORS         ;if Not, Jump to sensors
        CALL DO_FIRE_WEAPON     ;if Yes, Fire

    DO_SENSORS:
        INC SENSOR_TIMER        ;Increment counter
        CPI SENSOR_TIMER, 50    ;Only update every 50 loops (50ms)
        BRNE SKIP_SENSORS       ;If not 50 yet, skip sensor logic

        CLR SENSOR_TIMER        ;Reset counter
        CALL READ_TEMP          ;Update Temp
        CALL READ_DIST          ;Update Distance
        CALL Level2_LCD         ;Draw on screen

    SKIP_SENSORS:
        JMP OPERATIONAL_LOOP

	;INTERRUPT SERVICE ROUTINES (ISRs)
	FIRE_WEAPON:
		CALL DELAY_20ms         ;Debounce initial button press
		PUSH R16				;So that any DATA in the R16 is noot lost
		IN R16, SREG			;Saving the flag to R16
		PUSH R16				;So that we dont rewrite the latest flag

		SBR FLAGS, (1<<0)       ;Set Bit 0 of FLAGS to 1

		POP R16
		OUT SREG, R16
		POP R16
		RETI                    


	CHANGE_MODE:
		CALL DELAY_20ms         ;Debounce initial button press
		PUSH R16				;So that any DATA in the R16 is noot lost
		IN R16, SREG			;Saving the flag to R16
		PUSH R16				;So that we dont rewrite the latest flag
    
		SBR FLAGS, (1<<1)       ; Set Bit 1 of FLAGS to 1

		POP R16
		OUT SREG, R16
		POP R16
		RETI     
		
	RELOAD:
		CALL DELAY_20ms         ;Debounce initial button press
		PUSH R16				;So that any DATA in the R16 is noot lost
		IN R16, SREG			;Saving the flag to R16
		PUSH R16				;So that we dont rewrite the latest flag

		SBR FLAGS, (1<<2)       ; Set Bit 2 of FLAGS to 1

		POP R16
		OUT SREG, R16
		POP R16
		RETI                  

		;-------------------------------------Mode change and fire Logic---------------------------------------------
	DO_CHANGE_MODE:
		CPI MODE, 0             
		BREQ SET_AUTO			;if Mode = 0 we set it to 1(AUTO)  
		LDI MODE, 0             ;if not Set it to Single Mode
		RJMP END_TOGGLE         

	SET_AUTO:
		LDI MODE, 1             ; Set to Auto Mode

	END_TOGGLE:
		CALL Level1_LCD         ; Update the screen to show new mode
		RET


	DO_FIRE_WEAPON:
		CPI ENERGY, 0           ;Checks if we have any ammo
		BREQ FIRE_END           ;If energy is 0, jump to the end(Doesnt fire)

		;Turn on Fire Indicator LED
		SBI PORTC, LED_PIN

		;Step Motor
		CALL STEP_MOTOR         ; Triggers a 4-step magnetic sequence
		CALL DELAY_20ms			; Delay for the Motor to keep up with the LCD
		CALL DELAY_20ms
		CALL DELAY_20ms
    
		;Decrease Energy
		DEC ENERGY

		;Update Screen
		CALL Level1_LCD

		;Turn off Fire Indicator LED
		CBI PORTC, LED_PIN
	FIRE_END:
		RET

	DO_RELOAD:
		LDI ENERGY, 10          ; Reset Ammo
		LDI STEP_STATE, 0x06    ; Reset Stepper Sequence to 0 degrees
    
		;Clear all PINs
		CBI PORTD, 5 
		CBI PORTD, 4
		CBI PORTD, 1
		CBI PORTD, 0 

		CALL DELAY_1s

		;Set to 0 deg
		SBI PORTD, 5
		SBI PORTD, 1

		CALL DELAY_20ms
    
		; Update Screen
		CALL Level1_LCD
		RET

	; ---------------------------------------------Stepper Motor-------------------------------------
	STEP_MOTOR:
		;Bit-Shift Logic (Rotate Right 4-bits)
		LSR STEP_STATE          ; Shift all bits right by 1. Lowest bit falls into Carry.
		BRCC STEP_SKIP_ORI      ; If Carry is 0, skip the next line.
		ORI STEP_STATE, 0B00001000    ; If Carry is 1, inject a 1 into the top bit (Bit 3)
	STEP_SKIP_ORI:
		;Clear current motor pins
		CBI PORTD, 5 
		CBI PORTD, 4 
		CBI PORTD, 1 
		CBI PORTD, 0 

		;Map logical bits (3,2,1,0) to physical pins in a TRUE circular layout
		SBRC STEP_STATE, 3      ; Skip next instruction if Bit 3 is 0
		SBI PORTD, 5            ; Set IN2
    
		SBRC STEP_STATE, 2      ; Skip next instruction if Bit 2 is 0
		SBI PORTD, 4            ; Set IN1
    
		SBRC STEP_STATE, 1      ; Skip next instruction if Bit 1 is 0
		SBI PORTD, 1            ; Set IN3
    
		SBRC STEP_STATE, 0      ; Skip next instruction if Bit 0 is 0
		SBI PORTD, 0            ; Set IN4

		CALL DELAY_20ms         ; Give the magnetic gear time to physically move
    
		RET



	;================================================== LEVEL 2 ================================================

	;-------------------------------------------------TEMP SENSOR-------------------------------------------------
	READ_TEMP:
		CALL HANDSHAKE
		LDI R16, 0xCC           ; Skip ROM
		CALL WRITE_BYTE
		LDI R16, 0x44           ; Convert Temperature
		CALL WRITE_BYTE

		CALL DELAY_1s           ; Wait for DS18B20 ADC conversion

		CALL HANDSHAKE
		LDI R16, 0xCC           ; Skip ROM
		CALL WRITE_BYTE
		LDI R16, 0xBE           ; Read Scratchpad
		CALL WRITE_BYTE

		CALL READ_BYTE          ; Read Byte 0: LSB
		MOV R25, R16            ; Save LSB in R25
		CALL READ_BYTE          ; Read Byte 1: MSB
		MOV R24, R16            ; Save MSB in R24

		; A simple way to divide by 16 is to shift right 4 times
		LSR R24
		ROR R25
		LSR R24
		ROR R25
		LSR R24
		ROR R25
		LSR R24
		ROR R25
		MOV TEMP, R25
		RET

	;Temp Sensor Subroutines
	HANDSHAKE:
		SBI DDRC, TEMP_PIN      
		CBI PORTC, TEMP_PIN     
		CALL DELAY_480us       
    
		CBI DDRC, TEMP_PIN      
		RCALL DELAY_60us        
      
		RCALL DELAY_420us       
		RET

	WRITE_BYTE:
		LDI R17, 8              
	WB_LOOP:
		LSR R16                 
		BRCC WRITE_0
	WRITE_1:
		SBI DDRC, TEMP_PIN      
		CBI PORTC, TEMP_PIN     
		CALL DELAY_10us         
		CBI DDRC, TEMP_PIN      
		CALL DELAY_60us         
		RJMP WB_NEXT
	WRITE_0:
		SBI DDRC, TEMP_PIN      
		CBI PORTC, TEMP_PIN     
		CALL DELAY_60us         
		CBI DDRC, TEMP_PIN      
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
		CALL SDELAY
		CBI DDRC, TEMP_PIN
		CALL DELAY_10us
		
		CLC
		SBIC PINC, TEMP_PIN
		SEC
		
		ROR R16
		CALL DELAY_60us
		DEC R17
		BRNE RB_LOOP
		RET

	;---------------------------------------ULTRA SONIC-------------------------------------------
	READ_DIST:
		; Fire Ultrasonic Pulse
		SBI DDRC, TRIG_PIN
		SBI PORTC, TRIG_PIN
		CALL DELAY_10us
		CBI PORTC, TRIG_PIN

		; Setup Timer 1 (Prescaler 8)
		LDI R16, 0x00
		OUT TCNT1H, R16
		OUT TCNT1L, R16
		LDI R16, 0x02
		OUT TCCR1B, R16

		; Wait for Echo (with a safety timeout)
	WAIT_ECHO_HIGH:
		SBIS PINC, ECHO_PIN
		RJMP WAIT_ECHO_HIGH
	WAIT_ECHO_LOW:
		SBIC PINC, ECHO_PIN
		RJMP WAIT_ECHO_LOW

		; Stop Timer 1
		LDI R16, 0x00
		OUT TCCR1B, R16

		; Calculate Distance
		IN R24, TCNT1L
		IN R25, TCNT1H
    
		LDI R18, 0              ; Use R18 as safe Distance counter
	DIST_DIV_LOOP:
		SUBI R24, 58            ; Simplified divisor (58us per cm)
		SBCI R25, 0             ; Handle carry for 16-bit
		BRCS DIST_DIV_DONE      ; If R25:R24 < 58, stop
		INC R18
		RJMP DIST_DIV_LOOP
	DIST_DIV_DONE:
		MOV R26, R18            ; Move final result to R26 for your display routine
		RET

	;------------------------------------------------LCD PRINT LOGIC--------------------------------------------
	LCD_INIT:
		CALL DELAY_20ms
		LDI R16, 0x33			; Force LCD into 4-bit mode
		CALL CMNDWRT
		CALL DELAY_2ms
		LDI R16, 0x32			; Force LCD into 4-bit mode
		CALL CMNDWRT
		CALL DELAY_2ms
		LDI R16, 0x28			;4-bit mode, 2 lines, 5x7
		CALL CMNDWRT
		CALL DELAY_2ms
		LDI R16, 0x0C			; Display ON, cursor OFF
		CALL CMNDWRT
		LDI R16, 0x01			; Clear display
		CALL CMNDWRT
		CALL DELAY_2ms
		LDI R16, 0x06
		CALL CMNDWRT
		RET

	Level1_LCD:
		LDI R16, 0x80			;Line 1
		CALL CMNDWRT

		LDI ZH, HIGH(STR_E << 1)
		LDI ZL, LOW(STR_E << 1)
		CALL PRINT_STRING

		CPI ENERGY, 10			;if Energy = 10 next line is executed
		BREQ PRINT_TEN
    
		MOV R16, ENERGY
		ORI R16, '0'			;converting binary number to ASCII fot the LCD to be able to understand  
		CALL DATAWRT
		LDI R16, ' '			;Adding a space as there were 2 digits before(10)      
		CALL DATAWRT            
		RJMP CHECK_MODE			

	PRINT_TEN:
		LDI R16, '1'
		CALL DATAWRT
		LDI R16, '0'
		CALL DATAWRT

	CHECK_MODE:
		CPI MODE, 0				
		BREQ PRINT_MODE_S		;if Mode = 0 PRINT_MODE_S is executed
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

	Level2_LCD:
		LDI R16, 0xC0           ; Line 2 Start Address
		CALL CMNDWRT

		LDI ZH, HIGH(STR_DIST << 1)
		LDI ZL, LOW(STR_DIST << 1)
		CALL PRINT_STRING

		MOV R16, R26            ; Fetch calculated distance
		CALL PRINT_3_DIGIT      ; Print it as ASCII text

		LDI ZH, HIGH(STR_TEMP << 1)
		LDI ZL, LOW(STR_TEMP << 1)
		CALL PRINT_STRING

		MOV R16, TEMP           ; Fetch calculated temp
		CALL PRINT_2_DIGIT      ; Print it as ASCII text

		LDI R16, 'C'
		CALL DATAWRT
		RET

	; Hex to Text Converter (Hundreds, Tens, Ones)
	PRINT_3_DIGIT:
		CLR R17
	H_LOOP:
		SUBI R16, 100
		BRCS H_DONE
		INC R17
		RJMP H_LOOP
	H_DONE:
		SUBI R16, 156           ; Add 100 back (256-100)
		PUSH R16                ; Save remainder
		MOV R16, R17
		ORI R16, '0'            ; Convert to text
		CALL DATAWRT            
		POP R16
	PRINT_2_DIGIT:
		CLR R17
	T_LOOP:
		SUBI R16, 10
		BRCS T_DONE
		INC R17
		RJMP T_LOOP
	T_DONE:
		SUBI R16, 246           ; Add 10 back (256-10)
		PUSH R16
		MOV R16, R17
		ORI R16, '0'            ; Convert to text
		CALL DATAWRT            
		POP R16
		ORI R16, '0'            ; Print final ones digit
		CALL DATAWRT            
		RET



	;-----------------------------------------------DELAYS and Subroutines------------------------------------------

	;LCD Subroutines:
	CMNDWRT:
		MOV R27, R16
		ANDI R27, 0xF0
		OUT LCD_DPRT, R27		; send the high nibble
		CBI LCD_CPRT, LCD_RS	; RS = 0 for command
		SBI LCD_CPRT, LCD_EN	; EN = 1
		CALL SDELAY				; to make a wide EN pulse for the LCD to detect
		CBI LCD_CPRT, LCD_EN	; EN = 0
		CALL DELAY_100us

		; Send low nibble
		MOV R27, R16
		SWAP R27				;swap the nibbles
		ANDI R27, 0xF0			
		OUT LCD_DPRT, R27		;send the lower nibble
		SBI LCD_CPRT, LCD_EN	; EN = 1
		CALL SDELAY
		CBI LCD_CPRT, LCD_EN	; EN = 0
		CALL DELAY_100us
		RET

	DATAWRT:
		; Send high nibble
		MOV R27, R16
		ANDI R27, 0xF0
		OUT LCD_DPRT, R27
		SBI LCD_CPRT, LCD_RS	; RS = 1 for data
		SBI LCD_CPRT, LCD_EN	; EN = 1
		CALL SDELAY
		CBI LCD_CPRT, LCD_EN	; EN = 0
		CALL DELAY_100us

		; Send low nibble
		MOV R27, R16
		SWAP R27
		ANDI R27, 0xF0
		OUT LCD_DPRT, R27
		SBI LCD_CPRT, LCD_EN ; EN = 1
		CALL SDELAY
		CBI LCD_CPRT, LCD_EN ; EN = 0
		CALL DELAY_100us
		RET

	
	PRINT_STRING:
		LPM R16, Z+
		CPI R16, 0
		BREQ PRINT_STRING_DONE
		CALL DATAWRT
		RJMP PRINT_STRING
	PRINT_STRING_DONE:
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

	;DATA SECTION
	MESSAGE:
		.DB "ALTERRA OS BOOTING...", 0

	STR_E: 
		.DB "E:", 0, 0
	STR_MODE_S: 
		.DB " MODE:S", 0
	STR_MODE_A: 
		.DB " MODE:A", 0
	STR_DIST:
		.DB "DIS:", 0, 0
	STR_TEMP:
		.DB "cm |T:", 0, 0