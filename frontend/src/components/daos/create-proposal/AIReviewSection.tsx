import React, { useState } from "react";
import { CheckCircle2, XCircle, AlertCircle, Loader2 } from "lucide-react";
import { CONSTANTS } from "../../../constants";

interface AIReviewResponse {
  consistency_rating: number;
  assessment: string;
  feedback_details: string[];
}

interface AIReviewSectionProps {
  title: string;
  outcomeMessages: string[];
  description: string;
  onReviewComplete: (rating: number) => void;
  isDisabled?: boolean;
}

export const AIReviewSection: React.FC<AIReviewSectionProps> = ({
  title,
  outcomeMessages,
  description,
  onReviewComplete,
  isDisabled = false,
}) => {
  const [isLoading, setIsLoading] = useState(false);
  const [review, setReview] = useState<AIReviewResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [hasReviewed, setHasReviewed] = useState(false);

  const handleReview = async () => {
    setIsLoading(true);
    setError(null);
    
    try {
      const response = await fetch(`${CONSTANTS.apiEndpoint}api/review-proposal`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          title,
          outcomeMessages,
          description,
        }),
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || `Failed to review: ${response.statusText}`);
      }

      const reviewData: AIReviewResponse = await response.json();
      setReview(reviewData);
      setHasReviewed(true);
      onReviewComplete(reviewData.consistency_rating);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to get AI review");
      onReviewComplete(0);
    } finally {
      setIsLoading(false);
    }
  };

  const getRatingColor = (rating: number) => {
    if (rating >= 6) return "text-green-500";
    if (rating >= 4) return "text-yellow-500";
    return "text-red-500";
  };

  const getRatingIcon = (rating: number) => {
    if (rating >= 6) return <CheckCircle2 className="w-5 h-5" />;
    if (rating >= 4) return <AlertCircle className="w-5 h-5" />;
    return <XCircle className="w-5 h-5" />;
  };

  return (
    <div className="space-y-4 p-4 bg-gray-900 rounded-lg">
      <div className="flex items-center justify-between">
        <h3 className="text-lg font-medium text-gray-200">AI Proposal Review</h3>
        {!hasReviewed && (
          <button
            type="button"
            onClick={handleReview}
            disabled={isLoading || isDisabled || !title || !description || outcomeMessages.length < 2}
            className="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600 disabled:bg-gray-700 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {isLoading ? (
              <>
                <Loader2 className="w-4 h-4 animate-spin" />
                Reviewing...
              </>
            ) : (
              "Get AI Review"
            )}
          </button>
        )}
      </div>

      {error && (
        <div className="p-3 bg-red-900/20 border border-red-500 rounded-md">
          <p className="text-red-400 text-sm">{error}</p>
        </div>
      )}

      {review && (
        <div className="space-y-4">
          {/* Rating Display */}
          <div className="flex items-center gap-3">
            <div className={`flex items-center gap-2 ${getRatingColor(review.consistency_rating)}`}>
              {getRatingIcon(review.consistency_rating)}
              <span className="text-2xl font-bold">{review.consistency_rating}/10</span>
            </div>
            <span className="text-gray-400">Consistency Rating</span>
          </div>

          {/* Assessment */}
          <div className="p-3 bg-gray-800 rounded-md">
            <h4 className="text-sm font-medium text-gray-300 mb-2">Overall Assessment</h4>
            <p className="text-gray-200">{review.assessment}</p>
          </div>

          {/* Feedback Details */}
          {review.feedback_details.length > 0 && (
            <div className="space-y-2">
              <h4 className="text-sm font-medium text-gray-300">Detailed Feedback</h4>
              <ul className="space-y-2">
                {review.feedback_details.map((feedback, index) => (
                  <li key={index} className="flex items-start gap-2">
                    <span className="text-blue-400 mt-0.5">•</span>
                    <span className="text-gray-200 text-sm">{feedback}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {/* Warning if rating is below 6 */}
          {review.consistency_rating < 6 && (
            <div className="p-3 bg-yellow-900/20 border border-yellow-500 rounded-md">
              <p className="text-yellow-400 text-sm">
                <strong>Note:</strong> Your proposal needs a consistency rating of at least 6/10 to be submitted. 
                Please address the feedback above and try again.
              </p>
            </div>
          )}

          {/* Success message if rating is 6 or above */}
          {review.consistency_rating >= 6 && (
            <div className="p-3 bg-green-900/20 border border-green-500 rounded-md">
              <p className="text-green-400 text-sm">
                <strong>Great!</strong> Your proposal has passed the consistency check. You can now submit it.
              </p>
            </div>
          )}

          {/* Retry button if rating is below 6 */}
          {review.consistency_rating < 6 && (
            <button
              type="button"
              onClick={() => {
                setReview(null);
                setHasReviewed(false);
                onReviewComplete(0);
              }}
              className="px-4 py-2 bg-gray-700 text-white rounded hover:bg-gray-600"
            >
              Revise & Review Again
            </button>
          )}
        </div>
      )}
    </div>
  );
};