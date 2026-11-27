#include <AccelStepper.h>

// Verified RADDS v1.6 X-Axis Pins on Arduino Due
#define X_STEP_PIN   24
#define X_DIR_PIN    23
#define X_ENABLE_PIN 26

// Initialize AccelStepper in DRIVER mode
AccelStepper stepperX(AccelStepper::DRIVER, X_STEP_PIN, X_DIR_PIN);

// Motion & Timing Configuration
const long stepsPerRev   = 600;
const int  rotations     = 1;
const long targetSteps   = stepsPerRev * rotations; // Baseline main travel (1,200 steps)

// Randomization bounds for "a bit less distance" and variable pause time
const long minStepReduction = 30;                  // Minimum steps less than targetSteps
const long maxStepReduction = 120;                 // Maximum steps less than targetSteps (upper bound is exclusive in random())
const unsigned long minPauseMs = 2000;             // Minimum pause time (ms)
const unsigned long maxPauseMs = 4501;             // Upper bound for random() (exclusive -> up to 4,500 ms)

void setup() {
  // Seed PRNG from floating analog pin for varied patterns across power cycles
  randomSeed(analogRead(A0));

  // Enable the TMC2209 driver (Active LOW on RADDS)
  pinMode(X_ENABLE_PIN, OUTPUT);
  digitalWrite(X_ENABLE_PIN, LOW);

  // Configure pulse width, speed, and smooth acceleration
  stepperX.setMinPulseWidth(5);
  stepperX.setMaxSpeed(2000.0);
  stepperX.setAcceleration(1000.0);
}

void loop() {
  // 1. Move forward with slightly less distance than targetSteps
  long forwardReduction = random(minStepReduction, maxStepReduction);
  long forwardTarget = targetSteps - forwardReduction;
  stepperX.moveTo(forwardTarget);
  while (stepperX.distanceToGo() != 0) {
    stepperX.run();
  }

  // 2. Stop and hold position for a randomized pause duration
  delay(random(minPauseMs, maxPauseMs));

  // 3. Return to start (0)
  stepperX.moveTo(0);
  while (stepperX.distanceToGo() != 0) {
    stepperX.run();
  }

  // 4. Stop and hold position for another randomized pause duration
  delay(random(minPauseMs, maxPauseMs));
}