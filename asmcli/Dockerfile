# this is using debian, with a "minimal footprint" install for gcloud
FROM gcr.io/google.com/cloudsdktool/cloud-sdk:slim
# cloudbuild will override this variable:
ENV SERVICE_ACCOUNT my_sa_email_goes_here
# cloudbuild will override this variable:
ENV KEY_FILE path_to_a_key_file_goes_here
# cloudbuild will override this variable:
ENV USE_GKE_GCLOUD_AUTH_PLUGIN gcloud_plugin_goes_here
# install script dependencies
RUN apt-get install google-cloud-sdk-kpt jq kubectl google-cloud-sdk-gke-gcloud-auth-plugin -y
# install test dependencies
RUN apt-get install shellcheck posh bc procps openssl yamllint -y

# https://docs.bazel.build/versions/master/install-ubuntu.html
RUN \
  apt install apt-transport-https curl gnupg -y && \
  curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > bazel.gpg && \
  mv bazel.gpg /etc/apt/trusted.gpg.d/ && \
  echo "deb [arch=amd64] https://storage.googleapis.com/bazel-apt stable jdk1.8" | tee /etc/apt/sources.list.d/bazel.list && \
  apt update -y && apt install bazel -y

ENTRYPOINT [ "bash" ]
