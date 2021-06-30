# this is using debian, with a "minimal footprint" install for gcloud
FROM gcr.io/google.com/cloudsdktool/cloud-sdk:slim
# cloudbuild will mount a volume in this path
WORKDIR /workspace/
# cloudbuild will override this variable:
ENV SERVICE_ACCOUNT my_sa_email_goes_here
# cloudbuild will override this variable:
ENV KEY_FILE path_to_a_key_file_goes_here
# install script dependencies
RUN apt-get install jq kubectl ruby-full -y
# install test dependencies
RUN apt-get install shellcheck posh bc procps openssl yamllint -y
# copy source files into WORKDIR
COPY install_asm ./
COPY tests ./tests/
COPY Dockerfile ./
ENTRYPOINT [ "bash" ]
