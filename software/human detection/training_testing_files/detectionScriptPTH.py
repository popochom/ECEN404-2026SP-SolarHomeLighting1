import cv2
import torch
import numpy as np
import firebase_admin
from firebase_admin import credentials, db
from torchvision.models.detection import ssd300_vgg16
from torchvision import transforms
from PIL import Image

class PersonDetector:
    def __init__(self, model_path, confidence_threshold=0.5):
        # Set up device
        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        print(f"Using device: {self.device}")
        
        # Initialize model with 4 classes (background, person, bicycle, car)
        self.model = ssd300_vgg16(weights=None)
        self.model.head.classification_head.num_classes = 4
        
        # Load weights
        try:
            self.model.load_state_dict(torch.load(model_path, map_location=self.device))
            print("Successfully loaded model weights!")
        except Exception as e:
            print(f"Error loading model weights: {e}")
            raise
        
        self.model.to(self.device)
        self.model.eval()
        
        # Set confidence threshold
        self.confidence_threshold = confidence_threshold
        
        # Class 1 is person in our model
        self.person_class_id = 1
        
        # Set up transforms
        self.transform = transforms.Compose([
            transforms.Resize((300, 300)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
        ])
    
    def detect_person(self, frame):
        """
        Detect if any person is in the frame
        Returns: (is_person_present, confidence, box)
        """
        # Convert from BGR to RGB
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        pil_image = Image.fromarray(rgb_frame)
        orig_height, orig_width = frame.shape[:2]
        
        # Transform image
        img_tensor = self.transform(pil_image)
        img_tensor = img_tensor.unsqueeze(0).to(self.device)
        
        # Perform detection
        with torch.no_grad():
            detections = self.model(img_tensor)[0]
        
        # Process results - only interested in person class (1)
        # After getting detections
        boxes = detections['boxes'].cpu().numpy()
        scores = detections['scores'].cpu().numpy()
        labels = detections['labels'].cpu().numpy()
    
        # 1. Stricter threshold for person class to reduce false positives
        self.person_threshold = 0.50  # Higher than general threshold
    
        # 2. Add size filtering to remove unlikely detections
        filtered_indices = []
        for i, box in enumerate(boxes):
            if labels[i] == self.person_class_id and scores[i] >= self.person_threshold:
                x1, y1, x2, y2 = box
                width = x2 - x1
                height = y2 - y1
            
                # Filter by aspect ratio for persons (should be taller than wide)
                aspect_ratio = height / (width + 1e-6)
                min_size = 300 * 0.05  # At least 5% of image size
            
                if aspect_ratio > 0.8 and width > min_size and height > min_size:
                    filtered_indices.append(i)
    
        # Use filtered indices
        filtered_boxes = boxes[filtered_indices] if filtered_indices else []
        filtered_scores = scores[filtered_indices] if filtered_indices else []
        
        # Check if any person detected
        is_person_present = len(filtered_boxes) > 0
        
        # If person detected, return highest confidence detection
        if is_person_present:
            best_idx = np.argmax(filtered_scores)
            best_box = filtered_boxes[best_idx]
            best_score = filtered_scores[best_idx]
            
            # Scale box to original image size
            x1, y1, x2, y2 = best_box
            scaled_box = [
                int(x1 * orig_width / 300),
                int(y1 * orig_height / 300),
                int(x2 * orig_width / 300),
                int(y2 * orig_height / 300)
            ]
            
            return is_person_present, best_score, scaled_box
        
        return False, 0.0, None

# -------- Firebase Setup --------
userKey = '8BRff9bNFHPxHjtkJ93Z71WcqYA2'
cred = credentials.Certificate('solar-home-lighting-1-firebase-adminsdk-fbsvc-c06253cf01.json')
firebase_admin.initialize_app(cred, {
    'databaseURL': 'https://solar-home-lighting-1-default-rtdb.firebaseio.com/'
})

ref = db.reference(f'solar_data/users/{userKey}/sensorData/humanActivity')

ref.set(False)

# -------- Model Setup --------
# Replace with your actual model class
model_path = "saved models/ssd_multiclass_detector.pth"

# Initialize detector
detector = PersonDetector(model_path, confidence_threshold=0.5)

# -------- Main Camera Loop --------
cam = cv2.VideoCapture(1)
last_sent = None

while True:
    ret, frame = cam.read()
    if not ret:
        continue

    person_present, confidence, box = detector.detect_person(frame)

    # Send update only if state changes
    if person_present != last_sent:
        ref.set(person_present)
        print("Updated Firebase:", person_present)
        last_sent = person_present

    # For debugging, press 'q' to quit
    if cv2.waitKey(1) == ord('q'):
        break

cam.release()
cv2.destroyAllWindows()