/// GraphQL documents used for sync. Read-only queries; nothing here mutates GitHub.
///
/// Sync runs in two steps because GraphQL has no conditional requests: a cheap index of open
/// pull requests (with a fingerprint of what can change), then full detail only for pull
/// requests whose fingerprint moved.
enum GitHubQueries {
    static let authoredSearch = "is:pr is:open author:@me archived:false"
    static let reviewRequestedSearch = "is:pr is:open review-requested:@me archived:false"
    static let detailBatchSize = 10

    static let index = """
    query TernIndex($authored: String!, $requested: String!, $known: [ID!]!) {
      viewer { login databaseId }
      rateLimit { cost remaining resetAt }
      authored: search(query: $authored, type: ISSUE, first: 50) { nodes { ...TernIndexPR } }
      requested: search(query: $requested, type: ISSUE, first: 50) { nodes { ...TernIndexPR } }
      known: nodes(ids: $known) { ...TernIndexPR }
    }

    fragment TernIndexPR on PullRequest {
      id updatedAt headRefOid isDraft state
      repository { nameWithOwner }
      reviewRequests { totalCount }
      statusCheckRollup { state }
    }
    """

    static let detail = """
    query TernDetail($ids: [ID!]!) {
      rateLimit { cost remaining resetAt }
      nodes(ids: $ids) { ...TernPR }
    }

    fragment TernActor on Actor { __typename login }

    fragment TernReviewer on RequestedReviewer {
      __typename
      ... on User { login }
      ... on Bot { login }
      ... on Mannequin { login }
      ... on Team { slug }
    }

    fragment TernPR on PullRequest {
      id number title body url isDraft state merged createdAt updatedAt
      author { ...TernActor }
      headRefName headRefOid baseRefName
      repository { databaseId nameWithOwner }
      headRepository { nameWithOwner }
      reviewRequests(first: 20) { nodes { requestedReviewer { ...TernReviewer } } }
      reviews(last: 30) { nodes { databaseId state submittedAt author { ...TernActor } } }
      reviewThreads(last: 30) {
        nodes {
          id isResolved
          resolvedBy { login }
          comments(last: 1) { nodes { databaseId createdAt author { ...TernActor } } }
        }
      }
      comments(last: 20) { nodes { databaseId createdAt author { ...TernActor } } }
      timelineItems(last: 50, itemTypes: [REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, REVIEW_DISMISSED_EVENT]) {
        nodes {
          __typename
          ... on ReviewRequestedEvent { id createdAt actor { ...TernActor } requestedReviewer { ...TernReviewer } }
          ... on ReviewRequestRemovedEvent { id createdAt actor { ...TernActor } requestedReviewer { ...TernReviewer } }
          ... on ReadyForReviewEvent { id createdAt actor { ...TernActor } }
          ... on ConvertToDraftEvent { id createdAt actor { ...TernActor } }
          ... on MergedEvent { id createdAt actor { ...TernActor } }
          ... on ClosedEvent { id createdAt actor { ...TernActor } }
          ... on ReopenedEvent { id createdAt actor { ...TernActor } }
          ... on ReviewDismissedEvent { id createdAt actor { ...TernActor } review { databaseId } }
        }
      }
      commits(last: 1) { nodes { commit { oid committedDate author { user { login } } } } }
      statusCheckRollup {
        contexts(first: 50) {
          nodes {
            __typename
            ... on CheckRun { databaseId name status conclusion startedAt completedAt }
            ... on StatusContext { id context state createdAt }
          }
        }
      }
    }
    """
}
