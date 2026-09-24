# These resources existed under different addresses before the file
# reorganization. Without these `moved` blocks, Terraform treats the old
# and new addresses as two unrelated resources, destroying the old one
# and creating a brand new one, instead of recognizing it as a rename.

moved {
  from = aws_glue_job.transfer_orders
  to   = aws_glue_job.transform_orders
}

moved {
  from = aws_iam_role_policy.glue_s3_access
  to   = aws_iam_role_policy.glue_crawler_raw_s3_access
}

moved {
  from = aws_iam_role_policy_attachment.glue_service
  to   = aws_iam_role_policy_attachment.glue_crawler_service
}
