// Mimir IAM
resource "aws_iam_role" "mimir" {
  name               = "${local.name}-mimir"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "mimir_s3" {
  role       = aws_iam_role.mimir.name
  policy_arn = aws_iam_policy.mimir_s3_access.arn
}

resource "aws_eks_pod_identity_association" "mimir" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "mimir"
  role_arn        = aws_iam_role.mimir.arn
}

// Mimir blocks/alertmanager/ruler S3 buckets.
resource "aws_s3_bucket" "mimir_blocks" {
  bucket = "${local.name}-mimir-blocks"

  tags = local.tags
}

resource "aws_s3_bucket" "mimir_alertmanager" {
  bucket = "${local.name}-mimir-alertmanager"

  tags = local.tags
}

resource "aws_s3_bucket" "mimir_ruler" {
  bucket = "${local.name}-mimir-ruler"

  tags = local.tags
}

resource "aws_s3_bucket_versioning" "mimir_blocks" {
  bucket = aws_s3_bucket.mimir_blocks.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "mimir_alertmanager" {
  bucket = aws_s3_bucket.mimir_alertmanager.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "mimir_ruler" {
  bucket = aws_s3_bucket.mimir_ruler.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mimir_blocks" {
  bucket = aws_s3_bucket.mimir_blocks.id

  rule {
    bucket_key_enabled       = false
    blocked_encryption_types = ["SSE-C"]

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mimir_alertmanager" {
  bucket = aws_s3_bucket.mimir_alertmanager.id

  rule {
    bucket_key_enabled       = false
    blocked_encryption_types = ["SSE-C"]

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mimir_ruler" {
  bucket = aws_s3_bucket.mimir_ruler.id

  rule {
    bucket_key_enabled       = false
    blocked_encryption_types = ["SSE-C"]

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

// Lifecycle: longer retention for time-series blocks
resource "aws_s3_bucket_lifecycle_configuration" "mimir_blocks" {
  bucket = aws_s3_bucket.mimir_blocks.id

  rule {
    id     = "mimir_blocks_retention"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }

    filter {
      prefix = ""
    }
  }
}

// Lifecycle: shorter retention for alertmanager config blobs
resource "aws_s3_bucket_lifecycle_configuration" "mimir_alertmanager" {
  bucket = aws_s3_bucket.mimir_alertmanager.id

  rule {
    id     = "mimir_alertmanager_retention"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    filter {
      prefix = ""
    }
  }
}

// Lifecycle: shorter retention for ruler config blobs
resource "aws_s3_bucket_lifecycle_configuration" "mimir_ruler" {
  bucket = aws_s3_bucket.mimir_ruler.id

  rule {
    id     = "mimir_ruler_retention"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    filter {
      prefix = ""
    }
  }
}

resource "aws_s3_bucket_public_access_block" "mimir_blocks" {
  bucket = aws_s3_bucket.mimir_blocks.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "mimir_alertmanager" {
  bucket = aws_s3_bucket.mimir_alertmanager.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "mimir_ruler" {
  bucket = aws_s3_bucket.mimir_ruler.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

// IAM policy for Mimir SA to access all buckets
resource "aws_iam_policy" "mimir_s3_access" {
  name        = "${local.name}-mimir-s3-access"
  description = "Permissions for Mimir to read/write its blocks/alertmanager/ruler buckets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.mimir_blocks.arn,
          "${aws_s3_bucket.mimir_blocks.arn}/*",
          aws_s3_bucket.mimir_alertmanager.arn,
          "${aws_s3_bucket.mimir_alertmanager.arn}/*",
          aws_s3_bucket.mimir_ruler.arn,
          "${aws_s3_bucket.mimir_ruler.arn}/*"
        ]
      }
    ]
  })
}
