import { ImageResponse } from '@vercel/og';
import { NextRequest } from 'next/server';
import { CONSTANTS } from '../../../../constants';

export const runtime = 'edge';

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id } = await params;
    
    // Fetch DAO data
    const response = await fetch(
      `${CONSTANTS.apiEndpoint}daos?dao_id=${encodeURIComponent(id)}`,
      { next: { revalidate: 300 } }
    );
    
    if (!response.ok) {
      throw new Error('Failed to fetch DAO data');
    }
    
    const data = await response.json();
    const dao = data.data?.[0];
    
    if (!dao) {
      throw new Error('DAO not found');
    }
    
    return new ImageResponse(
      (
        <div
          style={{
            height: '100%',
            width: '100%',
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
            backgroundColor: '#1f2937',
            fontFamily: 'system-ui',
          }}
        >
          {/* Background pattern */}
          <div
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              backgroundImage: 'radial-gradient(circle at 1px 1px, #374151 1px, transparent 1px)',
              backgroundSize: '40px 40px',
              opacity: 0.3,
            }}
          />
          
          {/* Content */}
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '60px',
              textAlign: 'center',
            }}
          >
            {/* DAO Icon */}
            {dao.icon_url && (
              <img
                src={dao.icon_url}
                alt=""
                width={120}
                height={120}
                style={{
                  borderRadius: '50%',
                  marginBottom: '30px',
                  border: '4px solid #4b5563',
                }}
              />
            )}
            
            {/* DAO Name */}
            <h1
              style={{
                fontSize: '72px',
                fontWeight: 'bold',
                color: '#ffffff',
                marginBottom: '20px',
                lineHeight: 1.1,
              }}
            >
              {dao.dao_name}
            </h1>
            
            {/* Tokens */}
            <div
              style={{
                display: 'flex',
                gap: '40px',
                marginBottom: '30px',
              }}
            >
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '10px',
                }}
              >
                <div
                  style={{
                    backgroundColor: '#10b981',
                    padding: '8px 16px',
                    borderRadius: '8px',
                    fontSize: '24px',
                    fontWeight: '600',
                    color: '#ffffff',
                  }}
                >
                  {dao.asset_symbol}
                </div>
              </div>
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '10px',
                }}
              >
                <div
                  style={{
                    backgroundColor: '#3b82f6',
                    padding: '8px 16px',
                    borderRadius: '8px',
                    fontSize: '24px',
                    fontWeight: '600',
                    color: '#ffffff',
                  }}
                >
                  {dao.stable_symbol}
                </div>
              </div>
            </div>
            
            {/* Verified badge */}
            {dao.verification?.verified && (
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  backgroundColor: '#059669',
                  padding: '8px 20px',
                  borderRadius: '20px',
                  marginBottom: '30px',
                }}
              >
                <svg
                  width="20"
                  height="20"
                  viewBox="0 0 20 20"
                  fill="white"
                >
                  <path d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 111.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" />
                </svg>
                <span
                  style={{
                    color: '#ffffff',
                    fontSize: '18px',
                    fontWeight: '600',
                  }}
                >
                  Verified
                </span>
              </div>
            )}
            
            {/* Stats */}
            <div
              style={{
                display: 'flex',
                gap: '60px',
                marginTop: '20px',
              }}
            >
              {dao.proposal_count !== undefined && (
                <div
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'center',
                  }}
                >
                  <div
                    style={{
                      fontSize: '48px',
                      fontWeight: 'bold',
                      color: '#ffffff',
                    }}
                  >
                    {dao.proposal_count}
                  </div>
                  <div
                    style={{
                      fontSize: '20px',
                      color: '#9ca3af',
                    }}
                  >
                    Proposals
                  </div>
                </div>
              )}
              {dao.active_proposals !== undefined && (
                <div
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'center',
                  }}
                >
                  <div
                    style={{
                      fontSize: '48px',
                      fontWeight: 'bold',
                      color: '#ffffff',
                    }}
                  >
                    {dao.active_proposals}
                  </div>
                  <div
                    style={{
                      fontSize: '20px',
                      color: '#9ca3af',
                    }}
                  >
                    Active
                  </div>
                </div>
              )}
            </div>
          </div>
          
          {/* Footer */}
          <div
            style={{
              position: 'absolute',
              bottom: '40px',
              display: 'flex',
              alignItems: 'center',
              gap: '10px',
            }}
          >
            <div
              style={{
                fontSize: '24px',
                color: '#9ca3af',
                fontWeight: '600',
              }}
            >
              Govex
            </div>
            <div
              style={{
                fontSize: '20px',
                color: '#6b7280',
              }}
            >
              Futarchy on Sui
            </div>
          </div>
        </div>
      ),
      {
        width: 1200,
        height: 630,
      }
    );
  } catch (error) {
    console.error('Error generating OG image:', error);
    
    // Return a fallback image
    return new ImageResponse(
      (
        <div
          style={{
            height: '100%',
            width: '100%',
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
            backgroundColor: '#1f2937',
          }}
        >
          <div
            style={{
              fontSize: '60px',
              fontWeight: 'bold',
              color: '#ffffff',
            }}
          >
            Govex DAO
          </div>
          <div
            style={{
              fontSize: '24px',
              color: '#9ca3af',
              marginTop: '20px',
            }}
          >
            Futarchy on Sui
          </div>
        </div>
      ),
      {
        width: 1200,
        height: 630,
      }
    );
  }
}