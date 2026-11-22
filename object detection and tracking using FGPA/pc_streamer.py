# pc_streamer.py  — FIXED
import cv2
import serial
import numpy as np
import time
import sys

# ── Configuration ──────────────────────────────────────────────
PORT      = 'COM6'        # change to your port
BAUD      = 3_000_000
CAM_W     = 128
CAM_H     = 96
CAM_INDEX = 1

FRAME_START = bytes([0xFF, 0xFE, 0xFD])

# ── Open serial port ───────────────────────────────────────────
try:
    ser = serial.Serial(PORT, BAUD, timeout=1)
    print(f"Opened {PORT} at {BAUD} baud")
except serial.SerialException as e:
    print(f"ERROR: Cannot open {PORT}: {e}")
    sys.exit(1)

# ── Open camera ────────────────────────────────────────────────
cap = cv2.VideoCapture(CAM_INDEX)
cap.set(cv2.CAP_PROP_FRAME_WIDTH,  640)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
cap.set(cv2.CAP_PROP_FPS, 30)

cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)   # 0.25 = manual mode
cap.set(cv2.CAP_PROP_EXPOSURE, -6)           # fixed exposure value
cap.set(cv2.CAP_PROP_AUTO_WB, 0)             # disable auto white balance

if not cap.isOpened():
    print("ERROR: Cannot open camera")
    sys.exit(1)


print("Waiting 2 seconds for camera to settle...")
for _ in range(60):
    cap.read()
time.sleep(2)
print("Streaming started. Press Q to quit.\n")

frame_count = 0
t_start     = time.time()

try:
    while True:
        ret, frame = cap.read()
        if not ret:
            print("WARNING: Dropped frame")
            continue

        # Resize → grayscale
        small = cv2.resize(frame, (CAM_W, CAM_H),
                           interpolation=cv2.INTER_AREA)
        gray  = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)

        gray = np.clip(gray, 0, 252).astype(np.uint8)

        gray = cv2.GaussianBlur(gray, (3, 3), 0)

        # Preview on PC (4× zoom so you can see detail)
        preview = cv2.resize(gray, (CAM_W * 4, CAM_H * 4),
                             interpolation=cv2.INTER_NEAREST)
        cv2.imshow("PC Preview (what FPGA receives)", preview)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

        # Send frame
        payload = FRAME_START + gray.flatten().tobytes()
        ser.write(payload)

        # FPS counter
        frame_count += 1
        if frame_count % 30 == 0:
            fps = frame_count / (time.time() - t_start)
            print(f"FPS: {fps:.1f}  |  Bytes/frame: {len(payload)}",
                  end='\r')

except KeyboardInterrupt:
    print("\nStopped.")
finally:
    cap.release()
    ser.close()
    cv2.destroyAllWindows()