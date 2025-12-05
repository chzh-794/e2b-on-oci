package consts

import "os"

var (
	OCIRegion = os.Getenv("OCI_REGION") // e.g. "us-ashburn-1"

	// Namespace is what you see in OCIR (e.g. "ideshil2wbzt")
	OCIRNamespace = os.Getenv("OCIR_NAMESPACE")

	// Repository name, e.g. "e2b-templates"
	OCIRTemplateRepository = os.Getenv("OCIR_TEMPLATE_REPOSITORY")

	// Optional: full path override, e.g.
	// "us-ashburn-1.ocir.io/ideshil2wbzt/e2b-templates"
	OCIRTemplateRepositoryPath = os.Getenv("OCIR_TEMPLATE_REPOSITORY_PATH")
)
