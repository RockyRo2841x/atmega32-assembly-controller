	.INCLUDE "M32DEF.INC"

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
	.EQU BUZZ_PIN = 3
	.EQU ILED_PIN = 2
	;MCP3008
	.EQU MOSI = 5
	.EQU MISO = 6
	.EQU SCK  = 7
	.EQU CS   = 4

	; Variables
	.DEF ENERGY = R19
	.DEF MODE   = R20
	.DEF STEP_STATE = R22       ; Dedicate R22 to track which stepper phase we are on (0,1,2,3)
	.DEF TEMP = R23             ; Final Temperature
	.DEF TEMP_DATA = R24        ; RAW TEMP
	.DEF SENSOR_TIMER = R25
	.DEF LCD_TIMER = R28		;For the pages to rotate at certain intervals
	.DEF LCD_PAGE = R29

	;Dedicated a register for System Flags so ISRs dont block the CPU
	; Bit0 = Fire Weapon Requested
	; Bit1 = Change Mode Requested
	; Bit2 = Reload Requested
	; BIT3 = PG1
	; BIT4 = PG2
	; BIT5 = PG3
	.DEF FLAGS = R21

	;INTERRUPT VECTOR TABLE
	.ORG 0x0000
		JMP MAIN			; Reset Vector (Power on)

	.ORG 0x0002
		JMP FIRE_WEAPON		; INT0 Vector (Trigger Button)

	.ORG 0x0004
		JMP CHANGE_MODE		; INT1 Vector(Mode Button)

	.ORG 0x0006
		JMP RELOAD			; INT1 Vector(Reload button)

	MAIN:
		; Stack Pointer
		LDI R21, HIGH(RAMEND)
		OUT SPH, R21           
		LDI R21, LOW(RAMEND)
		OUT SPL, R21

		;Configure I/O Ports
		LDI R21, 0B11111111
		OUT LCD_DDDR, R21		; PORTA = Outputs (LCD)

		LDI R21, 0B11111011
		OUT DDRB, R21			; PORTB PIN PB2 = Reload
		SBI PORTB, 2			; INTERNAL PULL UP FOR RELOAD

		; PC7(Temp), PC5(Echo) are INPUTS. PC6(Trig), PC4(LED) are OUTPUTS
		LDI R21, 0B01011111
		OUT DDRC, R21

		SBI PORTC, 7				;Turn on internal pull up for Temp sensor
    
		LDI R21, 0B11110011			;(PD2 and PD3 are Inputs for buttons)
		OUT DDRD, R21

		SBI PORTD, 2				;Turn on internal pull up for Trigger
		SBI PORTD, 3				;Turn on internal pull up for Mode

		;Set Initial Variables
		LDI ENERGY, 10
		LDI MODE, 0
		LDI STEP_STATE, 0x06		;Start stepper sequence at binary 0110
    
		;Initialize the new FLAGS register to 0 to prevent accidental startup triggers
		CLR FLAGS               

		; MOTOR TO 0 DEGREES
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

	OPERATIONAL_LOOP:
		SBRC FLAGS, 0           ; If Fire Flag (Bit 0) is set, execute fire sequence
		CALL DO_FIRE_WEAPON
		SBRC FLAGS, 1           ; If Mode Flag (Bit 1) is set, change mode
		CALL DO_CHANGE_MODE
		SBRC FLAGS, 2           ; If Reload Flag (Bit 2) is set, reload weapon
		CALL DO_RELOAD

		CALL READ_TEMP          ;Takes 1 second
		CALL READ_DIST          
		CALL LEVEL3_LCD
		JMP OPERATIONAL_LOOP     

	;.....................................INTERRUPT SERVICE ROUTINES..........................................
	FIRE_WEAPON:
		CALL DELAY_20ms         ; Debounce initial button press
		PUSH R16				;So that any DATA in the R16 is noot lost
		IN R16, SREG			;Saving the flag to R16
		PUSH R16				;So that we dont re-write the latest flag

		SBR FLAGS, (1<<0)       ; Set Bit 0 of FLAGS to 1

		POP R16
		OUT SREG, R16
		POP R16
		RETI                    


	CHANGE_MODE:
		CALL DELAY_20ms         ; Debounce initial button press
		PUSH R16				;So that any DATA in the R16 is noot lost
		IN R16, SREG			;Saving the flag to R16
		PUSH R16				;So that we dont re-write the latest flag
    
		SBR FLAGS, (1<<1)       ; Set Bit 1 of FLAGS to 1

		POP R16
		OUT SREG, R16
		POP R16
		RETI     
		
	RELOAD:
		CALL DELAY_20ms         ; Debounce initial button press
		PUSH R16				;So that any DATA in the R16 is noot lost
		IN R16, SREG			;Saving the flag to R16
		PUSH R16				;So that we dont re-write the latest flag

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

Level3_LCD:

    INC LCD_TIMER
    CPI LCD_TIMER, 3        ;Wait 3 seconds per page(Since READ_TEMP takes 1s)
    BRNE DRAW_CURRENT       ;If not 3 sec refresh current page
    
    CLR LCD_TIMER           ;Reset timer
    INC LCD_PAGE            ;Move to next page
    CPI LCD_PAGE, 3         ;Have we gone TO PG2
    BRNE CLEAR_AND_DRAW
    CLR LCD_PAGE            ;Loop back to PG0

	CLEAR_AND_DRAW:
		LDI R16, 0x01           ; Wipes the LCD screen for a clean page transition
		CALL CMNDWRT
		CALL DELAY_2ms

	DRAW_CURRENT:
		CPI LCD_PAGE, 0
		BREQ PG0
		CPI LCD_PAGE, 1
		BREQ PG1
		RJMP PG2


	PG0:
	;..........................ENERGY
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
		RJMP TEMP

	PRINT_TEN:
		LDI R16, '1'
		CALL DATAWRT
		LDI R16, '0'
		CALL DATAWRT

	;......................TEMP
		LDI R16, 0xC0           ; Line 2 Start Address
		CALL CMNDWRT

		LDI ZH, HIGH(STR_TEMP << 1)
		LDI ZL, LOW(STR_TEMP << 1)
		CALL PRINT_STRING

		MOV R16, TEMP           ; Fetch calculated temp
		CALL PRINT_2_DIGIT      ; Print it as ASCII text

		LDI R16, 'C'
		CALL DATAWRT
		RET

	PG1:
	;........................DISTANCE
		LDI R16, 0x80			;Line 1
		CALL CMNDWRT
		LDI ZH, HIGH(STR_DIST << 1)
		LDI ZL, LOW(STR_DIST << 1)
		CALL PRINT_STRING

		MOV R16, R26            ;Fetch calculated distance
		CALL PRINT_3_DIGIT      ;Print it as ASCII text

		LDI R16, 'c'
		CALL DATAWRT
		LDI R16, 'm'
		CALL DATAWRT

	;........................PRESSURE
		LDI R16, 0xC0           ; Line 2 Start Address
		CALL CMNDWRT
		LDI ZH, HIGH(STR_PRES << 1)
		LDI ZL, LOW(STR_PRES << 1)
		CALL PRINT_STRING
		RET

	PG2:
	;........................MODE
		LDI R16, 0x80			;Line 1
		CALL CMNDWRT

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
		.DB "ENERGY:", 0
	STR_MODE_S: 
		.DB " MODE:SINGLE"
	STR_MODE_A: 
		.DB " MODE:AUTO"
	STR_DIST:
		.DB "DIST:", 0
	STR_TEMP:
		.DB "TEMP:", 0
	STR_PRES:
		.DB "PRESS:", 0, 0