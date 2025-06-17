import { Router } from 'express';
import { GoogleGenerativeAI } from '@google/generative-ai';
import { prisma } from '../../db';

const router = Router();

// Initialize Google Generative AI
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const GLOBAL_DAILY_LIMIT = parseInt(process.env.GLOBAL_DAILY_LIMIT || '100', 10);

if (!GEMINI_API_KEY) {
  throw new Error("GEMINI_API_KEY is not defined in your .env file");
}

const genAI = new GoogleGenerativeAI(GEMINI_API_KEY);
const geminiModel = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite-preview-06-17" });

// Define AI Review Prompt
const AI_REVIEW_PROMPT = `Please act as an expert proposal evaluator for a decentralized autonomous organization (DAO) operating a futarchy system. Your task is to analyze the provided proposal for internal logical consistency and potential errors.

Here are the details of the proposal:

**Title:**
{PROPOSAL_TITLE}

**Outcomes Defined by Proposal Creator:**
{PROPOSAL_OUTCOMES}

**Full Proposal Content (Description):**
{PROPOSAL_DESCRIPTION}

---

**Evaluation Task:**

Carefully review the entire proposal content, considering its title, the explicitly defined outcomes, and the detailed descriptions for each outcome. Focus on identifying:

1.  **Internal Contradictions:** Are there any statements or implications within the proposal that contradict each other?
2.  **Completeness & Clarity:** Is the impact of each outcome clearly defined and distinct? Does the introduction adequately set the stage for all outcomes?
3.  **Logical Flow:** Does the narrative make sense? Are there any missing pieces of information that would make an outcome ambiguous?
4.  **Adherence to Outcomes:** Does the "Full Proposal Content" consistently refer to and elaborate on *all* the "Outcomes Defined by Proposal Creator"?

**Output Requirements:**

1.  **Consistency Rating (1-10):** Provide a numerical rating from 1 to 10, where 1 is highly inconsistent/full of errors, and 10 is perfectly consistent/error-free.
2.  **Assessment and Feedback:**
    * Start with a concise overall assessment.
    * If the rating is less than 8, explicitly list the logical inconsistencies or errors found.
    * Suggest specific improvements to resolve these issues.
    * If the rating is 8 or higher, state that no significant inconsistencies were found, but offer minor suggestions for clarity if any exist.

**Your response should be in the following JSON format ONLY:**

\`\`\`json
{
  "consistency_rating": [number, 1-10],
  "assessment": "string describing overall assessment",
  "feedback_details": [
    "string detailing inconsistency 1 or suggestion 1",
    "string detailing inconsistency 2 or suggestion 2",
    // ... more details as needed
  ]
}
\`\`\``;

// API Endpoint for AI Review
router.post('/api/review-proposal', async (req: any, res: any) => {
  try {
    const { title, outcomeMessages, description } = req.body;

    // Validate inputs
    if (!title || typeof title !== 'string' || title.trim().length < 5) {
      return res.status(400).json({ error: "Proposal title is missing or too short (minimum 5 characters)." });
    }

    if (!outcomeMessages || !Array.isArray(outcomeMessages) || outcomeMessages.length < 2) {
      return res.status(400).json({ error: "Proposal must have at least 2 outcomes defined." });
    }

    if (!description || typeof description !== 'string' || description.trim().length < 50) {
      return res.status(400).json({ error: "Proposal description is missing or too short (minimum 50 characters)." });
    }

    // Format outcomes as a comma-separated list
    const formattedOutcomes = outcomeMessages.join(', ');

    // Use a Prisma transaction for a safe read-check-update operation
    const review = await prisma.$transaction(async (tx) => {
      const today = new Date();
      today.setUTCHours(0, 0, 0, 0); // Normalize to start of UTC day
      const metricKey = "globalAiReviewCount";

      // Find today's metric
      const dailyMetric = await tx.dailyMetric.findUnique({
        where: { key_date: { key: metricKey, date: today } },
      });

      // Check the limit
      if (dailyMetric && dailyMetric.count >= GLOBAL_DAILY_LIMIT) {
        throw new Error("GLOBAL_LIMIT_REACHED"); // Abort transaction with a specific error
      }

      // If checks pass, call the AI
      const promptWithData = AI_REVIEW_PROMPT
        .replace('{PROPOSAL_TITLE}', title)
        .replace('{PROPOSAL_OUTCOMES}', formattedOutcomes)
        .replace('{PROPOSAL_DESCRIPTION}', description);

      const result = await geminiModel.generateContent(promptWithData);
      const aiReviewText = result.response.text();

      // Extract JSON from the response
      let reviewJson;
      try {
        // Try to parse the response directly
        reviewJson = JSON.parse(aiReviewText);
      } catch (parseError) {
        // If direct parsing fails, try to extract JSON from markdown code block
        const jsonMatch = aiReviewText.match(/```json\n([\s\S]*?)\n```/);
        if (jsonMatch && jsonMatch[1]) {
          reviewJson = JSON.parse(jsonMatch[1]);
        } else {
          // Fallback: create a structured response from plain text
          reviewJson = {
            consistency_rating: 5,
            assessment: "Unable to parse AI response properly. The review was generated but formatting was incorrect.",
            feedback_details: [aiReviewText]
          };
        }
      }

      // Validate the response structure
      if (!reviewJson.consistency_rating || typeof reviewJson.consistency_rating !== 'number' || 
          reviewJson.consistency_rating < 1 || reviewJson.consistency_rating > 10) {
        reviewJson.consistency_rating = 5;
      }

      if (!reviewJson.assessment || typeof reviewJson.assessment !== 'string') {
        reviewJson.assessment = "Review completed but response format was invalid.";
      }

      if (!Array.isArray(reviewJson.feedback_details)) {
        reviewJson.feedback_details = [];
      }

      // Create or increment the counter
      await tx.dailyMetric.upsert({
        where: { key_date: { key: metricKey, date: today } },
        update: { count: { increment: 1 } },
        create: { key: metricKey, date: today, count: 1 },
      });
      
      return reviewJson; // Return the parsed JSON from the transaction
    });

    res.status(200).json(review);

  } catch (error: any) {
    // Handle the specific rate limit error
    if (error.message === "GLOBAL_LIMIT_REACHED") {
      return res.status(429).json({ 
        error: "The free AI reviewer has reached its daily capacity. Please try again tomorrow.",
        code: "GLOBAL_LIMIT_REACHED"
      });
    }
    
    // Handle other errors
    console.error("AI Review API Error:", error);
    res.status(500).json({ error: "An internal server error occurred while analyzing the proposal." });
  }
});

export default router;