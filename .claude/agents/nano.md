---
name: nano-agent
description: setup nano banana api in project
tools: Read, Write, MultiEdit, Bash, context7, playwright, shadcn-ui, firecrawl-mcp, taskmaster-ai, firebase
---


Here's how you can use the `@google/generative-ai` Node.js SDK to generate images with the Gemini API:

### 1\. Set Up Your Project

First, you need to set up your Node.js project. You'll need to install the official Google Generative AI SDK for JavaScript.

```bash
npm install @google/generative-ai
```

### 2\. Get Your API Key

To use the Gemini API, you need an API key. You can get one for free from **Google AI Studio**. Once you have your key, it's a best practice to store it as an environment variable to keep it secure.

```bash
export GEMINI_API_KEY="YOUR_API_KEY"
```

### 3\. Write the Code

Use the `GoogleGenAI` class from the SDK to initialize a client. Then, call the `generateContent` method on a model that supports image generation, such as `gemini-2.5-flash-image-preview`, and provide a text prompt describing the image you want to create.

```javascript
import { GoogleGenerativeAI } from "@google/generative-ai";
import fs from "fs";

async function generateImage() {
  const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY);
  const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-image-preview" });

  const prompt = "A cinematic photo of a large building with the text 'Gemini 2.5 can now generate long form text' projected on its front.";

  const result = await model.generateContent(prompt);
  const response = result.response;
  
  // The API returns the image data as part of the response
  const imagePart = response.candidates[0].content.parts.find(part => part.inlineData && part.inlineData.mimeType.startsWith('image/'));

  if (imagePart) {
    const imageBuffer = Buffer.from(imagePart.inlineData.data, 'base64');
    fs.writeFileSync("generated-image.png", imageBuffer);
    console.log("Image saved as generated-image.png");
  } else {
    console.log("No image was generated.");
    console.log("Full response:", JSON.stringify(response, null, 2));
  }
}

generateImage();
```

This code snippet shows you how to send a prompt to the model and save the generated image. The model's response will contain a part with `inlineData` that includes the image in a Base64-encoded format. You can then decode this and save it as a file.

-----

