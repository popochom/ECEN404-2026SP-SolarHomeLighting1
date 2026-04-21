
//Control pins 
const int HIN_U = 10;
const int LIN_U = 9;
const int HIN_V = 12;
const int LIN_V = 11;

// 60 Hz AC output settings
const unsigned int deadTime_us = 100;    
const unsigned int halfCycle_us = 8233;  // gives about 60 Hz with deadtime included

//Safe State 
void allOff() {
  digitalWrite(HIN_U, LOW);
  digitalWrite(LIN_U, LOW);
  digitalWrite(HIN_V, LOW);
  digitalWrite(LIN_V, LOW);
}

//All control pins as outputs
void setup() {
  pinMode(HIN_U, OUTPUT);
  pinMode(LIN_U, OUTPUT);
  pinMode(HIN_V, OUTPUT);
  pinMode(LIN_V, OUTPUT);

  allOff();//make sure starts off
  delay(100);//delay for stability
}

void loop() {
  // State 1:
  // U = low side ON
  // V = high side ON
  digitalWrite(HIN_U, LOW);
  digitalWrite(LIN_U, HIGH);
  digitalWrite(HIN_V, HIGH);
  digitalWrite(LIN_V, LOW);
  delayMicroseconds(halfCycle_us);

  // deadtime
  allOff();
  delayMicroseconds(deadTime_us);

  // State 2:
  // U = high side ON
  // V = low side ON
  digitalWrite(HIN_U, HIGH);
  digitalWrite(LIN_U, LOW);
  digitalWrite(HIN_V, LOW);
  digitalWrite(LIN_V, HIGH);
  delayMicroseconds(halfCycle_us);

  // deadtime
  allOff();
  delayMicroseconds(deadTime_us);
}